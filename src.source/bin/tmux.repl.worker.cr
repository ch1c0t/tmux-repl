require "pty"
require "../tmux_repl"

unless ARGV[0]? == "--worker"
  STDERR.puts "Usage: tmux.repl.worker --worker SESSION"
  exit 2
end

unless session_name = ARGV[1]?
  STDERR.puts "Missing session name."
  exit 2
end

base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
state_dir = File.join(base, "tmux-repl", session_name)
ready_path = File.join(state_dir, "worker.pid")
shutdown = Channel(Nil).new(1)

Process.on_terminate do |_reason|
  shutdown.send(nil)
end

channel = Global.amqp_channel
channel.prefetch(10)
commands = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(session_name))
events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(session_name))
session = PTY::Session.new(:sh)

begin
  session.start

  consumer_tag = commands.subscribe(
    no_ack: false,
    block: false,
    args: {"x-stream-offset": "next"}
  ) do |message|
    begin
      data = JSON.parse(message.body_io.to_s)
      if data["type"].as_s == "command"
        sequence = data["sequence"].as_i64.to_u64
        command = data["command"].as_s
        TmuxREPL.publish_event(events, "started", session_name, sequence, command: command)
        result = session.run(command) do |chunk|
          TmuxREPL.publish_event(events, "output", session_name, sequence, chunk: chunk)
        end
        TmuxREPL.publish_event(events, "complete", session_name, sequence, command: command, status: result.status)
      end
      message.ack
    rescue ex
      STDERR.puts "tmux.repl.worker: command failed: #{ex.message}"
      begin
        message.reject(requeue: false)
      rescue
      end
    end
  end

  File.write(ready_path, Process.pid.to_s)
  shutdown.receive
ensure
  session.terminate
  File.delete(ready_path) if File.exists?(ready_path)
end
