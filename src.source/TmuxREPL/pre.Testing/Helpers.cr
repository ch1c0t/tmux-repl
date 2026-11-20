private def input_pane : Tmux::Pane
  @input_pane || raise "Input pane is not available."
end

private def output_pane : Tmux::Pane
  @output_pane || raise "Output pane is not available."
end

private def pane_text(pane : Tmux::Pane) : String
  pane.capture_pane(join_wrapped: true).join("\n")
end

private def startup_diagnostics : String
  name = @session_name || return "REPL session not attached."
  state = State.new(name)
  files = %w[input.pid input.startup input.error output.pid output.startup output.error worker.pid worker.startup worker.error]
  states = files.map do |file|
    path = state.path(file)
    value = File.exists?(path) ? File.read(path).strip : "missing"
    "#{file}: #{value}"
  end
  panes = @server.session(name).active_window.panes.map_with_index do |pane, index|
    command = pane.display_message("\\#{pane_current_command}")
    capture = pane_text(pane).lines.last(8).join("\n")
    "pane[#{index}] id=#{pane.pane_id} index=#{pane.pane_index} active=#{pane.active?} size=#{pane.width}x#{pane.height} command=#{command.inspect}\n#{capture}"
  end
  (["session: #{name}", "state: #{state.base_path}"] + states + panes).join("\n")
rescue ex
  "Startup diagnostics failed: #{ex.class}: #{ex.message}"
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
