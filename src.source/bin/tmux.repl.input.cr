require "../input"

unless ARGV[0]? == "--input"
  STDERR.puts "Usage: tmux.repl.input --input SESSION"
  exit 2
end

unless session_name = ARGV[1]?
  STDERR.puts "Missing session name."
  exit 2
end

Input::Runner.new(session_name).run
