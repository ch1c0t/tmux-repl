require "../tmux_repl"

case ARGV[0]?
when "start"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).start
when "stop"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).stop
when "--repl"
  unless path = ARGV[1]?
    STDERR.puts "Missing output log path."
    exit 2
  end
  TmuxREPL.run_repl(path, ARGV[2]?)
else
  STDERR.puts "Unknown command or arguments."
  print_help
  exit 2
end
