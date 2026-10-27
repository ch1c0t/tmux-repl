require "file_utils"
require "json"
require "reply"
require "./tmux"
require "pty"
require "global-amqp_channel"

module TmuxREPL
  record Result, command : String, output : String, status : Int32
  
  def self.execute(command : String) : Result
    execute(command) { |_chunk| }
  end
  
  def self.execute(command : String, &stream_callback : String -> Nil) : Result
    output, status = PTY.run(["/bin/sh", "-c", command], &stream_callback)
    Result.new(command, output, status)
  end
  
  def self.write_result(path : String, result : Result) : Nil
    begin_result(path, result.command)
    append_output(path, result.output)
    finish_result(path, result)
  end
  
  def self.begin_result(path : String, command : String) : Nil
    File.open(path, "a") { |io| io.puts "$ #{command}" }
  end
  
  def self.append_output(path : String, output : String) : Nil
    return if output.empty?
    File.open(path, "a") { |io| io.print output }
  end
  
  def self.finish_result(path : String, result : Result) : Nil
    File.open(path, "a") do |io|
      io.puts unless result.output.empty? || result.output.ends_with?("\n")
      io.puts "[exit status: #{result.status}]"
      io.puts
    end
  end
  
  def self.run_repl(path : String, session_name : String? = nil) : Nil
    name = session_name || File.basename(File.dirname(path))
    stream = CommandStream.new(name)
    reader = Reply::Reader.new
    reader.read_loop do |expression|
      next if expression.strip.empty?
      stream.publish(expression)
      begin_result(path, expression)
      result = execute(expression) { |chunk| append_output(path, chunk) }
      finish_result(path, result)
    end
  end
  
  def self.show(path : String) : Nil
    Process.exec("tail", ["-n", "+1", "-f", path])
  end

  class CommandStream
    getter session_name : String
    getter name : String
    
    @sequence = 0_u64
    @queue : AMQP::Client::Queue
    
    def initialize(@session_name : String)
      component = @session_name.gsub(/[^a-zA-Z0-9._-]/, "_")
      component = "session" if component.empty?
      component = component[0, 220] if component.bytesize > 220
    
      @name = "tmux.repl.#{component}.commands"
      arguments = AMQP::Client::Arguments.new({"x-queue-type": "stream"})
      @queue = Global.amqp_channel.queue(@name, args: arguments)
    end
    
    def publish(command : String) : Nil
      @sequence &+= 1_u64
      payload = JSON.build do |json|
        json.object do
          json.field "type", "command"
          json.field "session", @session_name
          json.field "sequence", @sequence
          json.field "timestamp", Time.utc.to_s
          json.field "command", command
        end
      end
    
      properties = AMQP::Client::Properties.new(delivery_mode: 2)
      confirmed = @queue.publish_confirm(payload, props: properties)
      raise "LavinMQ did not confirm publish to stream #{@name}" unless confirmed
    end
  end

  class Session
    module Helpers
      private def state_dir : String
        base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
        File.join(base, "tmux-repl", @name)
      end
      
      private def repl_executable : String
        path = File.expand_path(PROGRAM_NAME)
        return path if File.basename(path) == "tmux.repl" && File::Info.executable?(path)
        "tmux.repl"
      end
      
      private def show_executable : String
        path = File.expand_path(PROGRAM_NAME)
        sibling = File.join(File.dirname(path), "tmux.show")
        File::Info.executable?(sibling) ? sibling : "tmux.show"
      end
      
      private def shell_quote(value : String) : String
        "'#{value.gsub("'", "'\\''")}'"
      end
    end
  
    module Start
      module CreateSession
        private def create_session(server : Tmux::Server, focus : Bool) : Nil
          dir = state_dir
          session : Tmux::Session? = nil
        
          begin
            FileUtils.mkdir_p(dir)
            log = File.join(dir, "output.log")
            File.write(log, "")
        
            created = server.new_session(name: @name, detached: true)
            session = created
            configure_session(created, log)
            activate(created) if focus
          rescue ex
            cleanup_failed_start(server, session, dir)
            STDERR.puts "tmux.repl: #{ex.message}"
            raise ex
          end
        end
        
        private def configure_session(session : Tmux::Session, log : String) : Nil
          window = session.active_window
          input_pane = window.active_pane
          output_pane = input_pane.split(:right, detached: true)
          window.select_layout("even-horizontal")
        
          input = input_command(input_pane, log)
          output = "#{shell_quote(show_executable)} #{shell_quote(log)}"
          input_pane.send_keys(input, literal: true)
          output_pane.send_keys(output, literal: true)
          input_pane.select
        end
        
        private def input_command(pane : Tmux::Pane, log : String) : String
          if command = @command
            pane.run!("pipe-pane", "-o", "-t", pane.pane_id, "cat >> #{shell_quote(log)}")
            command.map { |argument| shell_quote(argument) }.join(" ")
          else
            "#{shell_quote(repl_executable)} --repl #{shell_quote(log)} #{shell_quote(@name)}"
          end
        end
        
        private def cleanup_failed_start(server : Tmux::Server, session : Tmux::Session?, dir : String) : Nil
          begin
            if active_session = session
              active_session.kill
            else
              server.cmd("kill-session", "-t", @name)
            end
          rescue Tmux::Error
          end
          FileUtils.rm_rf(dir)
        end
      end
    
      def start(focus : Bool = true) : Nil
        server = current_server
        if session = find_session(server)
          activate(session) if focus
        else
          create_session(server, focus)
        end
      end
      
      include CreateSession
      
      private def current_server : Tmux::Server
        return Tmux::Server.new if ENV["TMUX"]?.nil?
        Tmux::Server.from_env
      end
      
      private def find_session(server : Tmux::Server) : Tmux::Session?
        return nil unless server.cmd("has-session", "-t", @name).success?
        server.session(@name)
      end
      
      private def activate(session : Tmux::Session) : Nil
        if ENV["TMUX"]?.nil?
          session.attach
        else
          session.switch_client
        end
      end
    end
  
    module Stop
      def stop : Nil
        begin
          server = ENV["TMUX"]?.nil? ? Tmux::Server.new : Tmux::Server.from_env
          server.cmd("kill-session", "-t", @name)
        rescue Tmux::Error
        ensure
          FileUtils.rm_rf(state_dir)
        end
      end
    end
  
    getter name : String
    getter command : Array(String)?
    
    def initialize(@name : String, @command : Array(String)? = nil)
      if command = @command
        raise ArgumentError.new("REPL command must not be empty") if command.empty?
      end
    end
    
    include Start
    include Stop
    include Helpers
  end
end