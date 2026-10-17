require "./tmux.repl/*"

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

case ARGV[0]?
when "start"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || "tmux-repl").start
when "stop"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || "tmux-repl").stop
when "--repl"
  unless path = ARGV[1]?
    STDERR.puts "Missing output log path."
    exit 2
  end
  TmuxREPL.run_repl(path)
else
  STDERR.puts "Unknown command or arguments."
  print_help
  exit 2
end
