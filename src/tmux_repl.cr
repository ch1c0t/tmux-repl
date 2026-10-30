require "file_utils"
require "json"
require "./tmux"
require "global-amqp_channel"

module TmuxREPL
  def self.component_name(session_name : String) : String
    component = session_name.gsub(/[^a-zA-Z0-9._-]/, "_")
    component = "session" if component.empty?
    component[0, 220]
  end
  
  def self.commands_queue_name(session_name : String) : String
    "tmux.repl.#{component_name(session_name)}.commands"
  end
  
  def self.events_queue_name(session_name : String) : String
    "tmux.repl.#{component_name(session_name)}.events"
  end
  
  def self.stream_queue(channel : AMQP::Client::Channel, name : String) : AMQP::Client::Queue
    channel.queue(name, args: AMQP::Client::Arguments.new({"x-queue-type": "stream"}))
  end
  
  def self.publish_message(
    queue : AMQP::Client::Queue,
    type : String,
    session_name : String,
    sequence : UInt64,
    command : String? = nil,
    chunk : String? = nil,
    status : Int32? = nil
  ) : Nil
    payload = JSON.build do |json|
      json.object do
        json.field "type", type
        json.field "session", session_name
        json.field "sequence", sequence
        json.field "timestamp", Time.utc.to_s
        json.field "command", command if command
        json.field "chunk", chunk if chunk
        json.field "status", status if status
      end
    end
    properties = AMQP::Client::Properties.new(delivery_mode: 2)
    raise "LavinMQ did not confirm publish to stream #{queue.name}" unless queue.publish_confirm(payload, props: properties)
  end
  
  def self.publish_event(
    queue : AMQP::Client::Queue,
    type : String,
    session_name : String,
    sequence : UInt64,
    command : String? = nil,
    chunk : String? = nil,
    status : Int32? = nil
  ) : Nil
    publish_message(queue, type, session_name, sequence, command, chunk, status)
  end
  
  def self.publish_command(
    queue : AMQP::Client::Queue,
    session_name : String,
    sequence : UInt64,
    command : String
  ) : Nil
    publish_message(queue, "command", session_name, sequence, command: command)
  end
  
  # Optional timing diagnostics for tracing command latency across the separate
  # input, worker, and output processes. Disabled unless explicitly requested.
  def self.trace_timing_enabled? : Bool
    ENV["TMUX_REPL_TRACE_TIMING"]? == "1"
  end
  
  def self.trace_timing(
    session_name : String,
    component : String,
    event : String,
    started_at : Time::Instant? = nil,
    details : String = ""
  ) : Nil
    return unless trace_timing_enabled?
  
    trace_path = ENV["TMUX_REPL_TRACE_FILE"]?
    unless trace_path
      base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
      trace_path = File.join(base, "tmux-repl", session_name, "timing.log")
    end
  
    elapsed = if start = started_at
      " elapsed_ms=#{(Time.instant - start).total_milliseconds.round(2)}"
    else
      ""
    end
    detail_suffix = details.empty? ? "" : " #{details}"
  
    File.open(trace_path, "a") do |file|
      file.puts "#{Time.utc} [#{component}] #{event}#{elapsed}#{detail_suffix}"
    end
  rescue
    # Diagnostic tracing must never interfere with REPL command execution.
  end

  class OutputView
    module Render
      # Draw the currently selected input and its output.
      def render(io : IO = STDOUT) : Nil
        io.print "\e[H\e[2J"
        io.flush
      
        unless selected = @selected_sequence
          io.puts "No inputs yet."
          io.flush
          return
        end
      
        command = @inputs[selected]?
        unless command
          io.puts "Waiting for input ##{selected}..."
          io.flush
          return
        end
      
        io.puts "INPUT ##{selected}"
        io.puts command
        io.puts "─" * 40
      
        if output = @outputs[selected]?
          io.print output
          io.puts unless output.ends_with?("\n") || output.empty?
        else
          io.puts "(running...)"
        end
      
        if status = @statuses[selected]?
          io.puts "[exit status: #{status}]"
        end
        io.flush
      end
    end
  
    module Update
      # Apply one event from the session event stream to the displayed view.
      def update(event : JSON::Any) : Nil
        sequence = event["sequence"].as_i64.to_u64
      
        case event["type"].as_s
        when "input"
          @inputs[sequence] = event["command"].as_s
          @selected_sequence = sequence
        when "select"
          @selected_sequence = sequence if @inputs.has_key?(sequence)
        when "output"
          chunk = event["chunk"].as_s
          @outputs[sequence] = @outputs.fetch(sequence, "") + chunk
        when "complete"
          @statuses[sequence] = event["status"].as_i64.to_i32
        end
      end
    end
  
    @inputs = {} of UInt64 => String
    @outputs = {} of UInt64 => String
    @statuses = {} of UInt64 => Int32
    @selected_sequence : UInt64?
    
    def initialize
      @selected_sequence = nil
    end
    
    include Update
    include Render
  end

  class Session
    module Helpers
      private def amqp_environment : Hash(String, String)
        socket_path = ENV["LAVINMQ_AMQP_UNIXSOCKET"]?
        raise "Missing critical environment configuration variable: LAVINMQ_AMQP_UNIXSOCKET" unless socket_path
      
        environment = {"LAVINMQ_AMQP_UNIXSOCKET" => socket_path}
        if TmuxREPL.trace_timing_enabled?
          environment["TMUX_REPL_TRACE_TIMING"] = "1"
          environment["TMUX_REPL_TRACE_FILE"] = File.join(state_dir, "timing.log")
        end
        environment
      end
      
      private def state_dir : String
        base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
        File.join(base, "tmux-repl", @name)
      end
      
      private def repl_executable : String
        sibling_executable("tmux.repl")
      end
      
      private def input_executable : String
        sibling_executable("tmux.repl.input")
      end
      
      private def output_executable : String
        sibling_executable("tmux.repl.output")
      end
      
      private def worker_executable : String
        sibling_executable("tmux.repl.worker")
      end
      
      private def sibling_executable(name : String) : String
        program_path = File.expand_path(PROGRAM_NAME)
        sibling = File.join(File.dirname(program_path), name)
        return sibling if File::Info.executable?(sibling)
      
        local_bin = File.expand_path(File.join("bin", name))
        return local_bin if File::Info.executable?(local_bin)
      
        if search_path = ENV["PATH"]?
          search_path.split(':').each do |directory|
            directory = "." if directory.empty?
            candidate = File.expand_path(name, directory)
            return candidate if File::Info.executable?(candidate)
          end
        end
      
        raise "Cannot find executable #{name.inspect} beside #{program_path.inspect} or on PATH"
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
          worker_process : Process? = nil
        
          begin
            FileUtils.mkdir_p(dir)
            unless @command
              File.write(File.join(dir, "input.startup"), "launching #{input_executable}")
            end
        
            created = if @command
              File.write(File.join(dir, "output.log"), "")
              server.new_session(name: @name, detached: true)
            else
              server.new_session(
                name: @name,
                detached: true,
                command: [input_executable, "--input", @name],
                environment: amqp_environment
              )
            end
            session = created
        
            unless @command
              wait_for_ready(File.join(dir, "input.pid"), "tmux.repl.input")
              File.write(File.join(dir, "worker.startup"), "launching #{worker_executable}")
              worker_process = Process.new(
                worker_executable,
                ["--worker", @name, created.session_id],
                input: Process::Redirect::Close,
                output: Process::Redirect::Close,
                error: Process::Redirect::Close
              )
              wait_for_ready(File.join(dir, "worker.pid"), "tmux.repl.worker")
            end
        
            configure_session(created)
        
            unless @command
              wait_for_ready(File.join(dir, "output.pid"), "tmux.repl.output")
            end
        
            activate(created) if focus
          rescue ex
            if process = worker_process
              begin
                Process.signal(Signal::TERM, process.pid)
                process.wait
              rescue
              end
            end
            cleanup_failed_start(server, session, dir)
            STDERR.puts "tmux.repl: #{ex.message}"
            raise ex
          end
        end
        
        private def wait_for_ready(path : String, process_name : String) : Nil
          error_path = path.sub(/\.pid$/, ".error")
          stage_path = path.sub(/\.pid$/, ".startup")
          deadline = Time.instant + 5.seconds
        
          while Time.instant < deadline
            if File.exists?(error_path)
              details = File.read(error_path).strip
              raise "#{process_name} failed before readiness: #{details}"
            end
        
            return if File.exists?(path)
            sleep 10.milliseconds
          end
        
          if File.exists?(error_path)
            details = File.read(error_path).strip
            raise "#{process_name} failed before readiness: #{details}"
          end
        
          stage = File.read(stage_path).strip if File.exists?(stage_path)
          detail = stage ? " while #{stage}" : ""
          raise "Timed out waiting for #{process_name} readiness at #{path}#{detail}"
        end
        
        private def configure_session(session : Tmux::Session) : Nil
          window = session.active_window
          input_pane = window.active_pane
        
          if @command
            log = File.join(state_dir, "output.log")
            input_pane.run!("pipe-pane", "-o", "-t", input_pane.pane_id, "cat >> #{shell_quote(log)}")
            input_pane.split(
              :right,
              detached: true,
              command: [output_executable, "--log", log]
            )
            input_pane.send_keys(input_command, literal: true)
          else
            File.write(File.join(state_dir, "output.startup"), "launching #{output_executable}")
            input_pane.split(
              :right,
              detached: true,
              command: [output_executable, @name]
            )
          end
        
          window.select_layout("even-horizontal")
          input_pane.select
        end
        
        private def input_command : String
          @command.not_nil!.map { |argument| shell_quote(argument) }.join(" ")
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
        stop_worker
      
        begin
          server = ENV["TMUX"]?.nil? ? Tmux::Server.new : Tmux::Server.from_env
          server.cmd("kill-session", "-t", @name)
        rescue Tmux::Error
        ensure
          FileUtils.rm_rf(state_dir)
        end
      end
      
      private def stop_worker : Nil
        ready_path = File.join(state_dir, "worker.pid")
        return unless File.exists?(ready_path)
      
        pid = File.read(ready_path).strip.to_i64?
        return unless pid
      
        begin
          Process.signal(Signal::TERM, pid)
        rescue
          return
        end
      
        deadline = Time.instant + 2.seconds
        while File.exists?(ready_path) && Time.instant < deadline
          sleep 10.milliseconds
        end
      
        if File.exists?(ready_path)
          begin
            Process.signal(Signal::KILL, pid)
          rescue
          end
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