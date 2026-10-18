require "./tmux.ictest/*"

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

require "../tmux"

module TmuxICTest
  def self.context_script : String
    executable = Process.executable_path || File.expand_path(PROGRAM_NAME)
    directory = File.dirname(executable)
    candidates = [
      File.expand_path("tmux.ictest.context.cr", directory),
      File.expand_path("../src/bin/tmux.ictest.context.cr", directory),
      File.expand_path("src/bin/tmux.ictest.context.cr", Dir.current),
    ]

    candidates.each do |path|
      return path if File.file?(path)
    end

    raise "Cannot find tmux.ictest.context.cr; run from the tmux-repl checkout or install the context script beside tmux.ictest"
  end

  def self.shell_quote(value : String) : String
    "'#{value.gsub("'", "'\\''")}'"
  end
end

if ARGV.includes?("--help") || ARGV.includes?("-h")
  puts "Usage: tmux.ictest"
  puts "Split the current tmux window and open IC Pry with the test context."
  exit
end

unless ENV["TMUX"]? && ENV["TMUX_PANE"]?
  STDERR.puts "tmux.ictest must be run inside a tmux pane."
  exit 2
end

caller_pane = Tmux::Pane.from_env
context_script = TmuxICTest.context_script
ic_executable = ENV["IC_EXECUTABLE"]? || "ic"
command = "TMUX_ICTEST_PARENT_PANE=#{TmuxICTest.shell_quote(caller_pane.pane_id)} #{TmuxICTest.shell_quote(ic_executable)} #{TmuxICTest.shell_quote(context_script)}"

caller_pane.split(:right, detached: false).send_keys(command, literal: true)
