private def process_message(data : JSON::Any, events) : Nil
  sequence = data["sequence"].as_i64.to_u64
  command = data["command"].as_s
  received_at = Time.instant

  TmuxREPL.trace_timing(
    @session_name, "worker", "command_received",
    details: "sequence=#{sequence} command_bytes=#{command.bytesize}"
  )

  publish_started(events, sequence, command)
  result = run_command(events, sequence, command)
  publish_complete(events, sequence, command, result.status, received_at)
end

private def publish_started(events, sequence, command) : Nil
  started_at = Time.instant
  TmuxREPL.publish_event(events, "started", @session_name, sequence, command: command)
  TmuxREPL.trace_timing(
    @session_name, "worker", "started_event_confirmed", started_at,
    "sequence=#{sequence}"
  )
end

private def run_command(events, sequence, command)
  run_started_at = Time.instant
  output_chunks = 0
  output_bytes = 0
  output_publish_ms = 0.0
  trace_timing = TmuxREPL.trace_timing_enabled?

  result = @session.run(command) do |chunk|
    output_chunks += 1
    output_bytes += chunk.bytesize

    if trace_timing
      output_publish_ms += publish_output(events, sequence, chunk)
    else
      TmuxREPL.publish_event(events, "output", @session_name, sequence, chunk: chunk)
    end
  end

  TmuxREPL.trace_timing(
    @session_name, "worker", "pty_run_finished", run_started_at,
    "sequence=#{sequence} status=#{result.status} output_chunks=#{output_chunks} output_bytes=#{output_bytes} output_publish_ms=#{output_publish_ms.round(2)}"
  )
  result
end

private def publish_output(events, sequence, chunk) : Float64
  started_at = Time.instant
  TmuxREPL.publish_event(events, "output", @session_name, sequence, chunk: chunk)
  (Time.instant - started_at).total_milliseconds
end

private def publish_complete(events, sequence, command, status, received_at) : Nil
  completed_at = Time.instant
  TmuxREPL.publish_event(events, "complete", @session_name, sequence, command: command, status: status)
  TmuxREPL.trace_timing(
    @session_name, "worker", "complete_event_confirmed", completed_at,
    "sequence=#{sequence}"
  )
  TmuxREPL.trace_timing(
    @session_name, "worker", "command_processing_finished", received_at,
    "sequence=#{sequence}"
  )
end
