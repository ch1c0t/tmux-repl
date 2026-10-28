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

def self.render_output(
  sequence : UInt64?,
  inputs : Hash(UInt64, String),
  outputs : Hash(UInt64, String),
  statuses : Hash(UInt64, Int32)
) : Nil
  STDOUT.print "\e[H\e[2J"
  STDOUT.flush

  unless selected = sequence
    puts "No inputs yet."
    STDOUT.flush
    return
  end

  command = inputs[selected]?
  unless command
    puts "Waiting for input ##{selected}..."
    STDOUT.flush
    return
  end

  puts "INPUT ##{selected}"
  puts command
  puts "─" * 40

  if output = outputs[selected]?
    print output
    puts unless output.ends_with?("\n") || output.empty?
  else
    puts "(running...)"
  end

  if status = statuses[selected]?
    puts "[exit status: #{status}]"
  end
  STDOUT.flush
end
