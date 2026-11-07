require "../tmux_repl"

case ARGV[0]?
when "start"
  arguments = ARGV[1..]
  no_focus = !arguments.delete("--no-focus").nil?
  if arguments.size > 1
    STDERR.puts "Usage: tmux.repl start [SESSION] [--no-focus]"
    exit 2
  end

  TmuxREPL::Session.new(
    arguments.first? || ENV["TMUX_REPL_SESSION"]? || generate_session_name
  ).start(focus: !no_focus)
when "stop"
  arguments = ARGV[1..]
  if arguments.size > 1
    STDERR.puts "Usage: tmux.repl stop [SESSION]"
    exit 2
  end

  TmuxREPL::Session.new(
    arguments.first? || ENV["TMUX_REPL_SESSION"]? || generate_session_name
  ).stop
else
  STDERR.puts "Unknown command or arguments."
  print_help
  exit 2
end
