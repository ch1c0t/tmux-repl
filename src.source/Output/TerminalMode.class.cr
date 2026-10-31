# Temporarily switches the output pane's terminal to character-at-a-time
# input so a single key can toggle the displayed transcript.
class TerminalMode
  @saved_state : String?

  def enable : Bool
    return false unless STDIN.tty?

    state = IO::Memory.new
    status = Process.run(
      "stty",
      ["-g"],
      input: STDIN,
      output: state,
      error: Process::Redirect::Close
    )
    return false unless status.success?

    saved_state = state.to_s.strip
    return false if saved_state.empty?
    @saved_state = saved_state

    status = Process.run(
      "stty",
      ["-echo", "-icanon", "min", "1", "time", "0"],
      input: STDIN,
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )
    unless status.success?
      restore
      return false
    end

    true
  rescue
    restore
    false
  end

  def restore : Nil
    state = @saved_state
    @saved_state = nil
    return unless state

    Process.run(
      "stty",
      [state],
      input: STDIN,
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )
    nil
  rescue
    nil
  end
end
