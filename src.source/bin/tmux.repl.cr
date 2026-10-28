require "reply"
require "../tmux_repl"

case ARGV[0]?
when "start"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).start
when "stop"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).stop
when "--repl"
  unless session_name = ARGV[1]?
    STDERR.puts "Missing session name."
    exit 2
  end

  commands = TmuxREPL.stream_queue(Global.amqp_channel, TmuxREPL.commands_queue_name(session_name))
  events = TmuxREPL.stream_queue(Global.amqp_channel, TmuxREPL.events_queue_name(session_name))
  reader = Reply::Reader.new
  sequence = 0_u64
  reader.read_loop do |expression|
    next if expression.strip.empty?
    sequence &+= 1_u64
    TmuxREPL.publish_event(events, "input", session_name, sequence, command: expression)
    payload = JSON.build do |json|
      json.object do
        json.field "type", "command"
        json.field "session", session_name
        json.field "sequence", sequence
        json.field "command", expression
      end
    end
    properties = AMQP::Client::Properties.new(delivery_mode: 2)
    raise "LavinMQ did not confirm command publish" unless commands.publish_confirm(payload, props: properties)
  end
else
  STDERR.puts "Unknown command or arguments."
  print_help
  exit 2
end
