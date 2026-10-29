require "pty"
require "../tmux_repl"

unless ARGV[0]? == "--worker"
  STDERR.puts "Usage: tmux.repl.worker --worker SESSION SESSION_ID"
  exit 2
end

unless session_name = ARGV[1]?
  STDERR.puts "Missing session name."
  exit 2
end

unless tmux_session_id = ARGV[2]?
  STDERR.puts "Missing tmux session ID."
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

session = PTY::Session.new(:sh)

begin
  channel = Global.amqp_channel
  channel.prefetch(10)
  File.write(startup_stage_path, "declaring command stream")
  commands = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(session_name))
  File.write(startup_stage_path, "declaring event stream")
  events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(session_name))
  File.write(startup_stage_path, "starting PTY session")
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
        command_received_at = Time.instant
        TmuxREPL.trace_timing(
          session_name, "worker", "command_received",
          details: "sequence=#{sequence} command_bytes=#{command.bytesize}"
        )

        publish_started_at = Time.instant
        TmuxREPL.publish_event(events, "started", session_name, sequence, command: command)
        TmuxREPL.trace_timing(
          session_name, "worker", "started_event_confirmed", publish_started_at,
          "sequence=#{sequence}"
        )

        pty_run_started_at = Time.instant
        output_chunks = 0
        output_bytes = 0
        output_publish_ms = 0.0
        trace_timing = TmuxREPL.trace_timing_enabled?
        result = session.run(command) do |chunk|
          output_chunks += 1
          output_bytes += chunk.bytesize

          publish_output_at = Time.instant if trace_timing
          TmuxREPL.publish_event(events, "output", session_name, sequence, chunk: chunk)
          if publish_started = publish_output_at
            output_publish_ms += (Time.instant - publish_started).total_milliseconds
          end
        end
        TmuxREPL.trace_timing(
          session_name, "worker", "pty_run_finished", pty_run_started_at,
          "sequence=#{sequence} status=#{result.status} output_chunks=#{output_chunks} output_bytes=#{output_bytes} output_publish_ms=#{output_publish_ms.round(2)}"
        )

        publish_complete_at = Time.instant
        TmuxREPL.publish_event(events, "complete", session_name, sequence, command: command, status: result.status)
        TmuxREPL.trace_timing(
          session_name, "worker", "complete_event_confirmed", publish_complete_at,
          "sequence=#{sequence}"
        )
        TmuxREPL.trace_timing(
          session_name, "worker", "command_processing_finished", command_received_at,
          "sequence=#{sequence}"
        )
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

  tmux_server = ENV["TMUX"]?.nil? ? Tmux::Server.new : Tmux::Server.from_env
  File.write(ready_path, Process.pid.to_s)
  File.delete(startup_stage_path) if File.exists?(startup_stage_path)

  # The worker belongs to the tmux session, not to a pane or the attached
  # client. Detaching leaves the session alive and therefore keeps the worker.
  loop do
    sleep 5.seconds
    break unless tmux_server.cmd("has-session", "-t", tmux_session_id).success?

    select
    when shutdown.receive
      break
    when timeout(250.milliseconds)
    end
  end
rescue ex
  File.write(startup_error_path, "#{ex.class}: #{ex.message}")
  STDERR.puts "tmux.repl.worker: #{ex.class}: #{ex.message}"
  exit 1
ensure
  begin
    session.terminate
  rescue
  end
  File.delete(ready_path) if File.exists?(ready_path)
end
