require "../tmux_repl"

case ARGV[0]?
when "start"
  # The testing runner injects this flag to exercise a detached session without
  # switching the developer's current Tmux client.
  focus = ENV["TMUX_REPL_TEST_FOCUS"]? != "0"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).start(focus: focus)
when "stop"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).stop
else
  STDERR.puts "Unknown command or arguments."
  print_help
  exit 2
end
