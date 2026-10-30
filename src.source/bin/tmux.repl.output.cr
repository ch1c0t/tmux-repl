require "../tmux_repl"

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

TmuxREPL::OutputProcess.new(session_name).run
