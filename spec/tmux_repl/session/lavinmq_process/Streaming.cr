module LavinMQProcess
  module Streaming
    private def verify_streaming_and_toggle : Nil
      command = %(for i in $(seq 1 4); do echo "Streaming Tick $i..." && sleep 0.2; done)
      input_pane.send_keys(command, literal: true)

      # The transcript is raw while the command is running.
      expect_output("Streaming Tick 1...", "START_MARK_", timeout: 3.seconds)
      raw = pane_text(output_pane)
      raw.should contain("END_MARK_")
      raw.should contain("Streaming Tick 1...")

      # Completion replaces that transcript with the stripped PTY result.
      expect_output("Streaming Tick 4...", "[exit status: 0]")
      expect_output_without("START_MARK_")
      expect_output_without("END_MARK_")

      # Ctrl+G from Input toggles to raw; the same key in Output toggles back.
      input_pane.send_keys("C-g")
      expect_output("START_MARK_", "END_MARK_", timeout: 2.seconds)

      output_pane.send_keys("C-g")
      expect_stripped_output
    end

    private def expect_stripped_output : Nil
      expect_output("Streaming Tick 1...", "Streaming Tick 4...", "[exit status: 0]", timeout: 2.seconds)
      expect_output_without("START_MARK_")
      expect_output_without("END_MARK_")
    end
  end
end
