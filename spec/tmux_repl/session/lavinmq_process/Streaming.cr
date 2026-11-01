module LavinMQProcess
  module Streaming
    private def verify_streaming_and_toggle : Nil
      command = %(for i in $(seq 1 4); do echo "Streaming Tick $i..." && sleep 0.2; done)
      input_pane.send_keys(command, literal: true)

      # The transcript is raw while the command is running.
      expect_output("Streaming Tick 1...", "START_MARK_", "END_MARK_", timeout: 3.seconds)

      # Completion replaces that transcript with the stripped PTY result.
      expect_output("Streaming Tick 4...", "[exit status: 0]")
      expect_output_without("START_MARK_")
      expect_output_without("END_MARK_")

      # Ctrl+G from Input toggles to raw; the same key in Output toggles back.
      toggle_view_from(input_pane)
      expect_output("START_MARK_", "END_MARK_", timeout: 2.seconds)

      toggle_view_from(output_pane)
      expect_stripped_output
      verify_keyboard_trace
    end

    private def toggle_view_from(pane : Tmux::Pane) : Nil
      # This is a standalone key press, not a submitted line.
      pane.send_keys("C-g", enter: false)
    end

    private def verify_keyboard_trace : Nil
      path = File.join(@state_home, "tmux-repl", name, "keyboard.trace.log")
      recorded = wait_until(3.seconds, 25.milliseconds) do
        next false unless File.exists?(path)

        content = File.read(path)
        content.includes?("pane=input") &&
          content.includes?("pane=output") &&
          content.includes?("action=ToggleOutputView")
      end

      fail_with_diagnostics("Keyboard trace did not record both panes and the Ctrl+G action at #{path}.") unless recorded

      content = File.read(path)
      expect_condition(content.includes?("pressed_at="), "Keyboard trace rows are missing press timestamps.")
      expect_condition(content.includes?("character='p'"), "Keyboard trace did not record ordinary input characters.")
      expect_condition(
        content.includes?("elapsed_since_previous_ms="),
        "Keyboard trace rows are missing inter-character elapsed times."
      )
      expect_condition(
        content.includes?("result=published"),
        "Keyboard trace did not record successful LavinMQ event publication."
      )
    end

    private def expect_stripped_output : Nil
      expect_output("Streaming Tick 1...", "Streaming Tick 4...", "[exit status: 0]", timeout: 2.seconds)
      expect_output_without("START_MARK_")
      expect_output_without("END_MARK_")
    end
  end
end
