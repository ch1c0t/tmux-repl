private def start_event_consumer : Nil
  name = @session_name || raise "The REPL session has not been identified."
  queue = TmuxREPL.stream_queue(
    Global.amqp_channel,
    TmuxREPL.events_queue_name(name)
  )
  events = Channel(Event).new(256)
  @event_channel = events

  queue.subscribe(
    no_ack: false,
    block: false,
    args: AMQ::Protocol::Table.new(
      {"x-stream-offset" => "next"} of String => AMQ::Protocol::Field
    )
  ) do |message|
    begin
      data = JSON.parse(message.body_io.to_s)
      if data["session"]?.try(&.as_s) == name
        sequence = data["sequence"]?.try(&.as_i64) || 0_i64
        status = data["status"]?.try { |value| value.as_i64.to_i32 }
        chunk = data["chunk"]?.try(&.as_s)
        clean_output = data["clean_output"]?.try(&.as_s)
        events.send(Event.new(data["type"].as_s, sequence, chunk, status, clean_output))
      end
      message.ack
    rescue ex
      STDERR.puts "tmux.repl.testing: could not read event: #{ex.class}: #{ex.message}"
      begin
        message.reject(requeue: false)
      rescue
      end
    end
  end
end
