require "../tmux_repl"

unless ARGV[0]? == "--input"
  STDERR.puts "Usage: tmux.repl.input --input SESSION"
  exit 2
end

unless session_name = ARGV[1]?
  STDERR.puts "Missing session name."
  exit 2
end

TmuxREPL::InputProcess.new(session_name).run
