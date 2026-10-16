require "../tmux_repl"

case ARGV[0]?
when "start"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || "tmux-repl").start
when "stop"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || "tmux-repl").stop
when "--repl"
  unless path = ARGV[1]?
    STDERR.puts "Missing output FIFO path."
    exit 2
  end
  TmuxREPL.run_repl(path)
when "--help", "help", "-h"
  print_help
else
  STDERR.puts "Unknown command or arguments."
  print_help
  exit 2
end
