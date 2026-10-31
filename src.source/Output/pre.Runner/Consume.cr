private def handle_message(
  message : AMQP::Client::DeliverMessage,
  view : View
) : Nil
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
        @session_name, "output", "event_rendered", render_started,
        "type=#{event_type} sequence=#{sequence}"
      )
    end
    if event_started = event_received_at
      TmuxREPL.trace_timing(
        @session_name, "output", "event_handled", event_started,
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
