require "file_utils"

module TmuxRepl
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
      FileUtils.mkdir_p(dir)
      fifo = File.join(dir, "output.fifo")
      File.delete(fifo) if File.exists?(fifo)
      Process.run("mkfifo", [fifo]).success? || raise "Could not create output FIFO"
      output = "cat #{shell_quote(fifo)}"
      input = "#{shell_quote(executable)} --repl #{shell_quote(fifo)}"
      Process.run("tmux", ["new-session", "-d", "-s", @name, output]).success? || raise "Could not start tmux session"
      Process.run("tmux", ["split-window", "-h", "-t", @name, input]).success? || raise "Could not create input pane"
      Process.run("tmux", ["select-layout", "-t", @name, "even-horizontal"])
      Process.run("tmux", ["attach-session", "-t", @name])
    rescue ex
      STDERR.puts "tmux-repl: #{ex.message}"
      raise ex
    end

    def stop : Nil
      tmux?("kill-session", "-t", @name)
      FileUtils.rm_rf(state_dir)
    end

    private def state_dir : String
      base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
      File.join(base, "tmux-repl", @name)
    end

    private def executable : String
      path = File.expand_path(PROGRAM_NAME)
      File.executable?(path) ? path : "tmux-repl"
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
end