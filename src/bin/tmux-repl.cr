require "./tmux-repl/*"

VERSION = "0.1.0"

case ARGV.size
when 1
  case ARGV[0]
  when "-v", "version", "--version"
    puts VERSION
    exit
  when "-h", "help", "--help"
    print_help
    exit
  end
end

module TmuxRepl
  record Result, command : String, stdout : String, stderr : String, status : Int32

  def self.execute(command : String) : Result
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run("/bin/sh", ["-lc", command], output: stdout, error: stderr)
    Result.new(command, stdout.to_s, stderr.to_s, status.exit_code)
  rescue ex
    Result.new(command, "", ex.message || ex.class.name, 1)
  end
end

module TmuxRepl
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
end

def print_help : Nil
  puts File.read(File.join(__DIR__, "help"))
end

require "reply"

module TmuxRepl
  def self.run_repl(path : String) : Nil
    reader = Reply::Reader.new
    reader.read_loop do |expression|
      next if expression.strip.empty?
      write_result(path, execute(expression))
    end
  end
end

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
require "./tmux-repl/*"

if ARGV.size == 1
  case ARGV[0]
  when "-v", "version", "--version"
    puts VERSION
    exit
  when "-h", "help", "--help"
    print_help
    exit
  end
end

case ARGV[0]?
when "start"
  TmuxRepl::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || "tmux-repl").start
when "stop"
  TmuxRepl::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || "tmux-repl").stop
when "--repl"
  unless path = ARGV[1]?
    STDERR.puts "Missing output FIFO path."
    exit 2
  end
  TmuxRepl.run_repl(path)
else
  STDERR.puts "Unknown command or arguments."
  print_help
  exit 2
end
