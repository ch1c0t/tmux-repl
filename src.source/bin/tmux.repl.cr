require "../tmux_repl"

case ARGV[0]?
when "start"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).start
when "stop"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).stop(ARGV[2]?)
when "__cleanup"
  name = ARGV[1]?
  state_directory = ARGV[2]?
  unless name && state_directory
    STDERR.puts "Usage: tmux.repl __cleanup SESSION STATE_DIRECTORY"
    exit 2
  end
  TmuxREPL::Session.new(name).cleanup_after_session_close(state_directory)
else
  STDERR.puts "Unknown command or arguments."
  print_help
  exit 2
end
