require "../tmux_repl"

unless path = ARGV[0]?
  STDERR.puts "Usage: tmux.show FIFO"
  exit 2
end

TmuxREPL.show(path)
