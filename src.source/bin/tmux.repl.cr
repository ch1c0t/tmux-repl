require "../tmux_repl"

case ARGV[0]?
when "start"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).start
when "stop"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).stop
else
  STDERR.puts "Unknown command or arguments."
  print_help
  exit 2
end
