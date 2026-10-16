require "file_utils"
require "reply"

module TmuxREPL
  record Result, command : String, stdout : String, stderr : String, status : Int32
  
  def self.execute(command : String) : Result
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run("/bin/sh", ["-c", command], output: stdout, error: stderr)
    Result.new(command, stdout.to_s, stderr.to_s, status.exit_code)
  rescue ex
    Result.new(command, "", ex.message || ex.class.name, 1)
  end
  
  def self.write_result(path : String, result : Result) : Nil
    File.open(path, "w") do |io|
      io.puts "$ #{result.command}"
      io.print result.stdout unless result.stdout.empty?
      io.print result.stderr unless result.stderr.empty?
      last = result.stderr.empty? ? result.stdout : result.stderr
      io.puts unless last.empty? || last.ends_with?("\n")
      io.puts "[exit status: #{result.status}]"
    end
  end
  
  def self.run_repl(path : String) : Nil
    reader = Reply::Reader.new
    reader.read_loop do |expression|
      next if expression.strip.empty?
      write_result(path, execute(expression))
    end
  end
  
  def self.show(path : String) : Nil
    loop do
      File.open(path, "r") do |input|
        IO.copy(input, STDOUT)
        STDOUT.flush
      end
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
        File::Info.executable?(path) ? path : "tmux.repl"
      end
      
      private def show_executable : String
        path = File.expand_path(PROGRAM_NAME)
        sibling = File.join(File.dirname(path), "tmux.show")
        File::Info.executable?(sibling) ? sibling : "tmux.show"
      end
      
      private def tmux?(*args : String) : Bool
        Process.run("tmux", args.to_a, output: Process::Redirect::Close, error: Process::Redirect::Close).success?
      rescue
        false
      end
      
      private def shell_quote(value : String) : String
        "'#{value.gsub("'", "'\\''")}'"
      end
    end
  
    module Start
      def start : Nil
        if tmux?("has-session", "-t", @name)
          Process.run("tmux", ["attach-session", "-t", @name])
          return
        else
          create
        end
      end
      
      def create
        Process.run("tmux", ["new-session", "-s", @name, "./bin/tmux.repl.input"])
        setup_right_pane
      end
      
      # Splits the window horizontally to create a right-hand output pane
      def setup_right_pane
        stdout = IO::Memory.new
        # Split window horizontally (-h), detached (-d), return target data (-P -F)
        status = Process.run(
          "tmux", 
          ["split-window", "-h", "-d", "-P", "-F", "\\\#{pane_tty}"], 
          output: stdout
        )
      
        unless status.success?
          raise "Failed to split Tmux window. Make sure Tmux is operational."
        end
      
        # Parse the target pane's pseudo-terminal path and hook into it
        right_pane_tty = stdout.to_s.strip
        @output_pane = File.open(right_pane_tty, "w")
      end
    end
  
    module Stop
      def stop : Nil
        tmux?("kill-session", "-t", @name)
        FileUtils.rm_rf(state_dir)
      end
    end
  
    getter name : String
    
    getter? in_tmux : Bool
    getter output_pane : File?
    
    def initialize(@name : String)
      raise ArgumentError.new("Invalid tmux session name") unless @name.matches?(/\A[a-zA-Z0-9_-]+\z/)
    
      # Check if the process is running inside an active Tmux environment
      @in_tmux = ENV.has_key?("TMUX")
      @output_pane = nil
    end
    
    include Start
    include Stop
    include Helpers
  end
end