require "../tmux_repl"

unless path = ARGV[0]?
  STDERR.puts "Usage: tmux.show LOG"
  exit 2
end

TmuxREPL.show(path)
