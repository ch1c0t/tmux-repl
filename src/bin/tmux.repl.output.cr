require "./tmux.repl.output/*"

VERSION = "0.1.0"

case ARGV.size
when 1
  case ARGV[0]
  when "-v", "version", "--version"
    puts VERSION
    exit
  when "-h", "help", "--help"
    print_help
    exit
  end
end

require "../tmux_repl"

if ARGV[0]? == "--log"
  unless path = ARGV[1]?
    STDERR.puts "Usage: tmux.repl.output --log LOG"
    exit 2
  end
  Process.exec("tail", ["-n", "+1", "-f", path])
end

unless session_name = ARGV[0]?
  STDERR.puts "Usage: tmux.repl.output SESSION"
  exit 2
end

base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
state_dir = File.join(base, "tmux-repl", session_name)
output_pid_path = File.join(state_dir, "output.pid")
startup_error_path = File.join(state_dir, "output.error")
startup_stage_path = File.join(state_dir, "output.startup")
File.delete(startup_error_path) if File.exists?(startup_error_path)
File.write(startup_stage_path, "connecting to LavinMQ")
events : AMQP::Client::Queue? = nil
consumer_tag : String? = nil

begin
  channel = Global.amqp_channel
  channel.prefetch(32)
  File.write(startup_stage_path, "declaring event stream")
  event_queue = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(session_name))
  events = event_queue
  view = TmuxREPL::OutputView.new
  shutdown = Channel(Nil).new(1)

  Process.on_terminate do |_reason|
    shutdown.send(nil)
  end

  File.write(startup_stage_path, "subscribing to event stream")
  consumer_tag = event_queue.subscribe(
    no_ack: false,
    block: false,
    args: {"x-stream-offset": "next"}
  ) do |message|
    begin
      data = JSON.parse(message.body_io.to_s)
      sequence = data["sequence"].as_i64.to_u64
      event_type = data["type"].as_s
      event_received_at = Time.instant if TmuxREPL.trace_timing_enabled?

      view.update(data)

      render_started_at = Time.instant if TmuxREPL.trace_timing_enabled?
      view.render
      if render_started = render_started_at
        TmuxREPL.trace_timing(
          session_name, "output", "event_rendered", render_started,
          "type=#{event_type} sequence=#{sequence}"
        )
      end
      if event_started = event_received_at
        TmuxREPL.trace_timing(
          session_name, "output", "event_handled", event_started,
          "type=#{event_type} sequence=#{sequence}"
        )
      end
      message.ack
    rescue ex
      STDERR.puts "tmux.repl.output: invalid event: #{ex.message}"
      begin
        message.reject(requeue: false)
      rescue
      end
    end
  end

  view.render
  File.write(output_pid_path, Process.pid.to_s)
  File.delete(startup_stage_path) if File.exists?(startup_stage_path)
  shutdown.receive
rescue ex
  File.write(startup_error_path, "#{ex.class}: #{ex.message}")
  STDERR.puts "tmux.repl.output: #{ex.class}: #{ex.message}"
  exit 1
ensure
  if event_queue = events
    if tag = consumer_tag
      begin
        event_queue.unsubscribe(tag)
      rescue
      end
    end
  end
  File.delete(output_pid_path) if File.exists?(output_pid_path)
end
