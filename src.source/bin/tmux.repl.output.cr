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
  inputs = {} of UInt64 => String
  outputs = {} of UInt64 => String
  statuses = {} of UInt64 => Int32
  selected_sequence : UInt64? = nil
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

    case data["type"].as_s
    when "input"
      inputs[sequence] = data["command"].as_s
      selected_sequence = sequence
    when "select"
      selected_sequence = sequence if inputs.has_key?(sequence)
    when "output"
      chunk = data["chunk"].as_s
      outputs[sequence] = outputs.fetch(sequence, "") + chunk
    when "complete"
      statuses[sequence] = data["status"].as_i64.to_i32
    end

    TmuxREPL.render_output(selected_sequence, inputs, outputs, statuses)
    message.ack
  rescue ex
    STDERR.puts "tmux.repl.output: invalid event: #{ex.message}"
    begin
      message.reject(requeue: false)
    rescue
    end
  end
end

  TmuxREPL.render_output(selected_sequence, inputs, outputs, statuses)
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
