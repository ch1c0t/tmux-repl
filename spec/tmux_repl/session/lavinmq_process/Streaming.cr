module LavinMQProcess
  module Streaming
    private def verify_streaming_and_toggle : Nil
      command = %(for i in $(seq 1 4); do echo "Streaming Tick $i..." && sleep 0.2; done)

      @stage = "submit streaming command"
      input_pane.send_keys(command, literal: true)

      # The transcript is raw while the command is running.
      @stage = "observe raw streamed output"
      expect_output("Streaming Tick 1...", "START_MARK_", "END_MARK_", timeout: 3.seconds)

      # Completion replaces that transcript with the stripped PTY result.
      expect_stripped_output

      # Ctrl+G from Input toggles to raw; the same key in Output toggles back.
      @stage = "toggle output to raw from the input pane"
      toggle_view_from(input_pane)

      @stage = "verify raw output after input-pane toggle"
      expect_output("START_MARK_", "END_MARK_", timeout: 2.seconds)

      @stage = "toggle output to stripped from the output pane"
      toggle_view_from(output_pane)
      expect_stripped_output

      verify_output_scrolling
      verify_keyboard_trace
    end

    private def verify_output_scrolling : Nil
      command = %(for i in $(seq 1 60); do printf 'SCROLL_LINE_%02d\\n' "$i"; done)

      @stage = "submit scrolling command"
      input_pane.send_keys(command, literal: true)

      @stage = "wait for final scrolling output"
      expect_output("SCROLL_LINE_60", "[exit status: 0]", timeout: 3.seconds)

      # PageUp moves through output retained above the viewport.
      @stage = "scroll to the beginning of command output"
      4.times { output_pane.send_keys("PageUp", enter: false) }
      expect_output("SCROLL_LINE_01")
      expect_output_without("SCROLL_LINE_60")

      # Arrows move one line; page keys move one viewport.
      @stage = "scroll down one line"
      output_pane.send_keys("Down", enter: false)
      expect_output("SCROLL_LINE_02")

      @stage = "scroll back to the latest output"
      4.times { output_pane.send_keys("PageDown", enter: false) }
      expect_output("SCROLL_LINE_60")
    end

    private def toggle_view_from(pane : Tmux::Pane) : Nil
      # This is a standalone key press, not a submitted line.
      pane.send_keys("C-g", enter: false)
    end

    private def verify_keyboard_trace : Nil
      @stage = "wait for keyboard trace events"
      path = File.join(@state_home, "tmux-repl", name, "keyboard.trace.log")
      recorded = wait_until(3.seconds, 25.milliseconds) do
        next false unless File.exists?(path)

        content = File.read(path)
        content.includes?("pane=input") &&
          content.includes?("pane=output") &&
          content.includes?("action=ToggleOutputView")
      end

      fail_with_diagnostics("Keyboard trace did not record both panes and the Ctrl+G action at #{path}.") unless recorded

      @stage = "verify keyboard trace fields"
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
      expect_condition(
        content.includes?("action=SubmitInput"),
        "Keyboard trace did not record the Enter key action."
      )
      expect_condition(
        content.includes?("key=Ctrl+Up") && content.includes?("action=SelectPrevious"),
        "Keyboard trace did not record Ctrl+Up input selection."
      )
      expect_condition(
        content.includes?("key=Ctrl+Down") && content.includes?("action=SelectNext"),
        "Keyboard trace did not record Ctrl+Down input selection."
      )
      expect_condition(
        content.includes?("key=PageUp") && content.includes?("action=ScrollPageUp"),
        "Keyboard trace did not record output PageUp scrolling."
      )
    end

    private def expect_stripped_output : Nil
      @stage = "wait for stripped command output"
      expect_output("Streaming Tick 1...", "Streaming Tick 4...", "[exit status: 0]", timeout: 2.seconds)

      @stage = "assert stripped output excludes START_MARK_"
      expect_output_without("START_MARK_")

      @stage = "assert stripped output excludes END_MARK_"
      expect_output_without("END_MARK_")
    end
  end
end
