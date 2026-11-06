# Optional timing diagnostics for tracing command latency across the separate
# input, worker, and output processes. Disabled unless explicitly requested.
def trace_timing_enabled? : Bool
  ENV["TMUX_REPL_TRACE_TIMING"]? == "1"
end

def trace_timing(
  session_name : String,
  component : String,
  event : String,
  started_at : Time::Instant? = nil,
  details : String = ""
) : Nil
  return unless trace_timing_enabled?

  trace_path = ENV["TMUX_REPL_TRACE_FILE"]? || State.open(session_name).log_path("timing.log")

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
