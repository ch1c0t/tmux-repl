require "../worker"

unless ARGV[0]? == "--worker"
  STDERR.puts "Usage: tmux.repl.worker --worker SESSION SESSION_ID"
  exit 2
end

unless session_name = ARGV[1]?
  STDERR.puts "Missing session name."
  exit 2
end

unless tmux_session_id = ARGV[2]?
  STDERR.puts "Missing tmux session ID."
  exit 2
end

Worker::Runner.new(session_name, tmux_session_id).run
