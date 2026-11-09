def publish_message(
  queue : AMQP::Client::Queue,
  type : String,
  session_name : String,
  sequence : UInt64,
  command : String? = nil,
  chunk : String? = nil,
  status : Int32? = nil,
  clean_output : String? = nil,
  action : String? = nil,
  requesting_pane : String? = nil
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
      json.field "clean_output", clean_output if clean_output
      json.field "action", action if action
      json.field "requesting_pane", requesting_pane if requesting_pane
    end
  end
  properties = AMQP::Client::Properties.new(delivery_mode: 2)
  raise "LavinMQ did not confirm publish to stream #{queue.name}" unless queue.publish_confirm(payload, props: properties)
end

def publish_event(
  queue : AMQP::Client::Queue,
  type : String,
  session_name : String,
  sequence : UInt64,
  command : String? = nil,
  chunk : String? = nil,
  status : Int32? = nil,
  clean_output : String? = nil,
  action : String? = nil,
  requesting_pane : String? = nil
) : Nil
  publish_message(queue, type, session_name, sequence, command, chunk, status, clean_output, action, requesting_pane)
end

def publish_command(
  queue : AMQP::Client::Queue,
  session_name : String,
  sequence : UInt64,
  command : String
) : Nil
  publish_message(queue, "command", session_name, sequence, command: command)
end
