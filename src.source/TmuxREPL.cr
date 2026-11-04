def self.define(name : String, &configure : Definition ->) : Definition
  definition = Definition.new(name)
  yield definition
  definition
end

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

extend Publishing
extend TraceTiming
