require "./tmux.repl.output/*"

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

require "../output"

if ARGV[0]? == "--log"
  unless path = ARGV[1]?
    STDERR.puts "Usage: tmux.repl.output --log LOG"
    exit 2
  end
  Process.exec("tail", ["-n", "+1", "-f", path])
end

unless session_name = ARGV[0]?
  STDERR.puts "Usage: tmux.repl.output SESSION"
  exit 2
end

Output::Runner.new(session_name).run
