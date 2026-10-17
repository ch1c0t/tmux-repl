require "./tmux.show/*"

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

require "../tmux_repl"

unless path = ARGV[0]?
  STDERR.puts "Usage: tmux.show LOG"
  exit 2
end

TmuxREPL.show(path)
