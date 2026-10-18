getter session_name : String
getter name : String

@sequence = 0_u64
@queue : AMQP::Client::Queue

def initialize(@session_name : String)
  component = @session_name.gsub(/[^a-zA-Z0-9._-]/, "_")
  component = "session" if component.empty?
  component = component[0, 220] if component.bytesize > 220

  @name = "tmux.repl.#{component}.commands"
  arguments = AMQP::Client::Arguments.new({"x-queue-type": "stream"})
  @queue = Global.amqp_channel.queue(@name, args: arguments)
end

def publish(command : String) : Nil
  @sequence &+= 1_u64
  payload = JSON.build do |json|
    json.object do
      json.field "type", "command"
      json.field "session", @session_name
      json.field "sequence", @sequence
      json.field "timestamp", Time.utc.to_s
      json.field "command", command
    end
  end

  properties = AMQP::Client::Properties.new(delivery_mode: 2)
  confirmed = @queue.publish_confirm(payload, props: properties)
  raise "LavinMQ did not confirm publish to stream #{@name}" unless confirmed
end
