def self.component_name(session_name : String) : String
  component = session_name.gsub(/[^a-zA-Z0-9._-]/, "_")
  component = "session" if component.empty?
  component[0, 220]
end

def self.commands_queue_name(session_name : String) : String
  "tmux.repl.#{component_name(session_name)}.commands"
end

def self.events_queue_name(session_name : String) : String
  "tmux.repl.#{component_name(session_name)}.events"
end

def self.stream_queue(channel : AMQP::Client::Channel, name : String) : AMQP::Client::Queue
  channel.queue(name, args: AMQP::Client::Arguments.new({"x-queue-type": "stream"}))
end

def self.publish_message(
  queue : AMQP::Client::Queue,
  type : String,
  session_name : String,
  sequence : UInt64,
  command : String? = nil,
  chunk : String? = nil,
  status : Int32? = nil
) : Nil
  payload = JSON.build do |json|
    json.object do
      json.field "type", type
      json.field "session", session_name
      json.field "sequence", sequence
      json.field "timestamp", Time.utc.to_s
      json.field "command", command if command
      json.field "chunk", chunk if chunk
      json.field "status", status if status
    end
  end
  properties = AMQP::Client::Properties.new(delivery_mode: 2)
  raise "LavinMQ did not confirm publish to stream #{queue.name}" unless queue.publish_confirm(payload, props: properties)
end

def self.publish_event(
  queue : AMQP::Client::Queue,
  type : String,
  session_name : String,
  sequence : UInt64,
  command : String? = nil,
  chunk : String? = nil,
  status : Int32? = nil
) : Nil
  publish_message(queue, type, session_name, sequence, command, chunk, status)
end

def self.publish_command(
  queue : AMQP::Client::Queue,
  session_name : String,
  sequence : UInt64,
  command : String
) : Nil
  publish_message(queue, "command", session_name, sequence, command: command)
end

# Optional timing diagnostics for tracing command latency across the separate
# input, worker, and output processes. Disabled unless explicitly requested.
def self.trace_timing_enabled? : Bool
  ENV["TMUX_REPL_TRACE_TIMING"]? == "1"
end

def self.trace_timing(
  session_name : String,
  component : String,
  event : String,
  started_at : Time::Instant? = nil,
  details : String = ""
) : Nil
  return unless trace_timing_enabled?

  trace_path = ENV["TMUX_REPL_TRACE_FILE"]?
  unless trace_path
    base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
    trace_path = File.join(base, "tmux-repl", session_name, "timing.log")
  end

  elapsed = if start = started_at
    " elapsed_ms=#{(Time.instant - start).total_milliseconds.round(2)}"
  else
    ""
  end
  detail_suffix = details.empty? ? "" : " #{details}"

  File.open(trace_path, "a") do |file|
    file.puts "#{Time.utc} [#{component}] #{event}#{elapsed}#{detail_suffix}"
  end
rescue
  # Diagnostic tracing must never interfere with REPL command execution.
end
