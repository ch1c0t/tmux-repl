private def connect
  channel = Global.amqp_channel
  channel.prefetch(10)

  write_startup_stage("declaring command stream")
  commands = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(@session_name))

  write_startup_stage("declaring event stream")
  events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(@session_name))
  {commands, events}
end

private def subscribe(commands, events) : Nil
  commands.subscribe(
    no_ack: false,
    block: false,
    args: AMQ::Protocol::Table.new({"x-stream-offset" => "next"} of String => AMQ::Protocol::Field)
  ) do |message|
    begin
      data = JSON.parse(message.body_io.to_s)
      process_message(data, events) if data["type"].as_s == "command"
      message.ack
    rescue ex
      STDERR.puts "tmux.repl.worker: command failed: #{ex.message}"
      begin
        message.reject(requeue: false)
      rescue
      end
    end
  end
  nil
end
