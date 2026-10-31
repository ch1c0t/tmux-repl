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
    end

    private def toggle_view_from(pane : Tmux::Pane) : Nil
      # This is a standalone key press, not a submitted line.
      pane.send_keys("C-g", enter: false)
    end

    private def expect_stripped_output : Nil
      expect_output("Streaming Tick 1...", "Streaming Tick 4...", "[exit status: 0]", timeout: 2.seconds)
      expect_output_without("START_MARK_")
      expect_output_without("END_MARK_")
    end
  end
end
