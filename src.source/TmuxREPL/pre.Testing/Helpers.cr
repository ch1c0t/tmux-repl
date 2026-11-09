private def input_pane : Tmux::Pane
  @input_pane || raise "Input pane is not available."
end

private def output_pane : Tmux::Pane
  @output_pane || raise "Output pane is not available."
end

private def pane_text(pane : Tmux::Pane) : String
  pane.capture_pane(join_wrapped: true).join("\n")
end

private def wait_until(
  timeout : Time::Span? = nil,
  interval : Time::Span = 25.milliseconds,
  &condition : -> Bool
) : Bool
  deadline = Time.instant + (timeout || @timeout)
  while Time.instant < deadline
    return true if yield
    sleep interval
  end
  yield
end

private def current_client_session_name : String?
  output = IO::Memory.new
  status = Process.run(
    "tmux",
    ["display-message", "-p", "\#{client_session}"],
    output: output,
    error: Process::Redirect::Close
  )
  return nil unless status.success?

  output.to_s.strip
rescue
  nil
end
