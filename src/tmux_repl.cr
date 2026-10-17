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
    File.open(path, "a") do |io|
      io.puts "$ #{result.command}"
      io.print result.stdout unless result.stdout.empty?
      if !result.stderr.empty?
        io.puts unless result.stdout.empty? || result.stdout.ends_with?("\n")
        io.print result.stderr
      end
      last = result.stderr.empty? ? result.stdout : result.stderr
      io.puts unless last.empty? || last.ends_with?("\n")
      io.puts "[exit status: #{result.status}]"
      io.puts
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
    Process.exec("tail", ["-n", "+1", "-f", path])
  end

  class Session
    getter name : String
    
    def initialize(@name : String)
      raise ArgumentError.new("Invalid tmux session name") unless @name.matches?(/\A[a-zA-Z0-9_-]+\z/)
    end
    
    def start : Nil
      if tmux?("has-session", "-t", @name)
        Process.run("tmux", ["attach-session", "-t", @name])
        return
      end
    
      dir = state_dir
      log = File.join(dir, "output.log")
      created = false
    
      begin
        FileUtils.mkdir_p(dir)
        File.write(log, "")
    
        input = "#{shell_quote(repl_executable)} --repl #{shell_quote(log)}"
        output = "#{shell_quote(show_executable)} #{shell_quote(log)}"
        raise "Could not start tmux session" unless tmux?("new-session", "-d", "-s", @name, input)
        created = true
        raise "Could not create output pane" unless tmux?("split-window", "-h", "-t", @name, output)
        raise "Could not select tmux layout" unless tmux?("select-layout", "-t", @name, "even-horizontal")
        ensure_input_pane_left
        raise "Could not focus input pane" unless tmux?("select-pane", "-t", "#{@name}:0.0")
        raise "Could not attach to tmux session" unless Process.run("tmux", ["attach-session", "-t", @name]).success?
      rescue ex
        tmux?("kill-session", "-t", @name) if created
        FileUtils.rm_rf(dir)
        STDERR.puts "tmux.repl: #{ex.message}"
        raise ex
      end
    end
    
    def stop : Nil
      tmux?("kill-session", "-t", @name)
      FileUtils.rm_rf(state_dir)
    end
    
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

    private def ensure_input_pane_left : Nil
      input_pane = "#{@name}:0.0"
      output_pane = "#{@name}:0.1"
      if pane_left(input_pane) > pane_left(output_pane)
        raise "Could not move input pane to the left" unless tmux?("swap-pane", "-d", "-s", input_pane, "-t", output_pane)
      end
    end

    private def pane_left(pane : String) : Int32
      stdout = IO::Memory.new
      status = Process.run(
        "tmux",
        ["display-message", "-p", "-t", pane, "\#{pane_left}"],
        output: stdout,
        error: Process::Redirect::Close
      )
      raise "Could not determine tmux pane position" unless status.success?
      stdout.to_s.strip.to_i
    end
  end
end
