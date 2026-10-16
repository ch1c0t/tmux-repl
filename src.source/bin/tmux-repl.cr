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
