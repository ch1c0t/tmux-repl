# Publish the input event before sending the command to the worker.
private def submit(
  expression : String,
  events : AMQP::Client::Queue,
  commands : AMQP::Client::Queue,
  history : History
) : Nil
  sequence = history.add(expression)
  command_received_at = Time.instant
  TmuxREPL.trace_timing(
    @session_name, "input", "command_received",
    details: "sequence=#{sequence} command_bytes=#{expression.bytesize}"
  )

  input_event_started_at = Time.instant if TmuxREPL.trace_timing_enabled?
  TmuxREPL.publish_event(events, "input", @session_name, sequence, command: expression)
  if publish_started = input_event_started_at
    TmuxREPL.trace_timing(
      @session_name, "input", "input_event_confirmed", publish_started,
      "sequence=#{sequence}"
    )
  end

  command_publish_started_at = Time.instant if TmuxREPL.trace_timing_enabled?
  TmuxREPL.publish_command(commands, @session_name, sequence, expression)
  if publish_started = command_publish_started_at
    TmuxREPL.trace_timing(
      @session_name, "input", "command_publish_confirmed", publish_started,
      "sequence=#{sequence}"
    )
  end

  TmuxREPL.trace_timing(
    @session_name, "input", "submission_published", command_received_at,
    "sequence=#{sequence}"
  )
  puts "[input ##{sequence}] submitted. Use :select ID, :prev, :next, :list, or :help."
end
