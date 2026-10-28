require "pty"
require "../tmux_repl"

unless ARGV[0]? == "--worker"
  STDERR.puts "Usage: tmux.repl.input --worker SESSION"
  exit 2
end

unless session_name = ARGV[1]?
  STDERR.puts "Missing session name."
  exit 2
end

channel = Global.amqp_channel
commands = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(session_name))
events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(session_name))
session = PTY::Session.new(:sh)
session.start

commands.subscribe(no_ack: false, block: true, args: {"x-stream-offset": "next"}) do |message|
  begin
    data = JSON.parse(message.body_io.to_s)
    next unless data["type"]?.try(&.as_s?) == "command"
    sequence = data["sequence"].as_i64.to_u64
    command = data["command"].as_s
    TmuxREPL.publish_event(events, "started", session_name, sequence, command: command)
    result = session.run(command) do |chunk|
      TmuxREPL.publish_event(events, "output", session_name, sequence, chunk: chunk)
    end
    TmuxREPL.publish_event(events, "complete", session_name, sequence, command: command, status: result.status)
    message.ack
  rescue ex
    STDERR.puts "tmux.repl.input: #{ex.message}"
    message.reject(requeue: false)
  end
end
