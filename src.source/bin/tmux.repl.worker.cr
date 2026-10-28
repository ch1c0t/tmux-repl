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
startup_error_path = File.join(state_dir, "worker.error")
startup_stage_path = File.join(state_dir, "worker.startup")
File.delete(startup_error_path) if File.exists?(startup_error_path)
File.write(startup_stage_path, "connecting to LavinMQ")
shutdown = Channel(Nil).new(1)

Process.on_terminate do |_reason|
  shutdown.send(nil)
end

session : PTY::Session? = nil

begin
  channel = Global.amqp_channel
  channel.prefetch(10)
  File.write(startup_stage_path, "declaring command stream")
  commands = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(session_name))
  File.write(startup_stage_path, "declaring event stream")
  events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(session_name))
  File.write(startup_stage_path, "starting PTY session")
  running_session = PTY::Session.new(:sh)
  session = running_session
  running_session.start

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
        result = running_session.run(command) do |chunk|
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
  File.delete(startup_stage_path) if File.exists?(startup_stage_path)
  shutdown.receive
rescue ex
  File.write(startup_error_path, "#{ex.class}: #{ex.message}")
  STDERR.puts "tmux.repl.worker: #{ex.class}: #{ex.message}"
  exit 1
ensure
  if running_session = session
    begin
      running_session.terminate
    rescue
    end
  end
  File.delete(ready_path) if File.exists?(ready_path)
end
