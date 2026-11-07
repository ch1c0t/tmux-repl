require "../tmux_repl"

delay = ENV["TMUX_REPL_TEST_DELAY"]?.try(&.to_f?) || 0.8
delay = 0.0 if delay < 0

begin
  TmuxREPL::Testing.run(
    "tmux.repl",
    cleanup: :never,
    restore_client: true,
    step_delay: delay.seconds
  ) do |test|
    test.step("Run ./bin/tmux.repl start") do
      test.start_cli("./bin/tmux.repl", ["start"])
    end

    test.step("Find the new session and its two panes") do
      test.expect_visible("No inputs yet.", timeout: 3.seconds)
    end

    test.step("Submit the first command") do
      command = test.submit(%(printf 'SMOKE_FIRST_OUTPUT\\n'))
      command.expect_output("SMOKE_FIRST_OUTPUT").expect_status(0)
    end

    test.step("Submit the second command") do
      command = test.submit(%(printf 'SMOKE_SECOND_OUTPUT\\n'))
      command.expect_output("SMOKE_SECOND_OUTPUT").expect_status(0)
    end

    test.step("Ctrl+Up selects the previous output") do
      test.press(:input, "C-Up")
      test.expect_selected_input(1)
      test.expect_visible("SMOKE_FIRST_OUTPUT")
    end

    test.step("Ctrl+Down selects the next output") do
      test.press(:input, "C-Down")
      test.expect_selected_input(2)
      test.expect_visible("SMOKE_SECOND_OUTPUT")
    end

    test.step("Alt+K selects the previous output") do
      test.press(:input, "M-k")
      test.expect_selected_input(1)
      test.expect_visible("SMOKE_FIRST_OUTPUT")
    end

    test.step("Alt+J selects the next output") do
      test.press(:input, "M-j")
      test.expect_selected_input(2)
      test.expect_visible("SMOKE_SECOND_OUTPUT")
    end

    test.step("Ctrl+L opens the available-outputs list from the input pane") do
      test.press(:input, "C-l")
      test.expect_visible("AVAILABLE OUTPUTS (2)", "#1", "#2")
    end

    test.step("Ctrl+L closes the list from the output pane") do
      test.press(:output, "C-l")
      test.expect_visible("INPUT #2", "SMOKE_SECOND_OUTPUT")
    end

    test.step("Submit a command for raw/stripped view testing") do
      command = %(for i in $(seq 1 4); do printf 'SMOKE_STREAM_TICK_%s\\n' "$i" && sleep 0.15; done)
      test.submit(command).expect_output("SMOKE_STREAM_TICK_4").expect_status(0)
    end

    test.step("Ctrl+G from the input pane switches to raw output") do
      test.press(:input, "C-g")
      test.expect_visible("[RAW;", "START_MARK_", "END_MARK_")
    end

    test.step("Ctrl+G from the output pane switches back to stripped output") do
      test.press(:output, "C-g")
      test.expect_visible("[STRIPPED;", "SMOKE_STREAM_TICK_4")
      test.expect_output_without("START_MARK_")
      test.expect_output_without("END_MARK_")
    end

    test.step("Submit a command with enough lines to scroll") do
      command = %(for i in $(seq 1 60); do printf 'SMOKE_SCROLL_LINE_%02d\\n' "$i"; done)
      test.submit(command).expect_output("SMOKE_SCROLL_LINE_60").expect_status(0)
    end

    test.step("PageUp in the output pane reaches the first lines") do
      4.times { test.press(:output, "PageUp") }
      test.expect_visible("SMOKE_SCROLL_LINE_01")
      test.expect_output_without("SMOKE_SCROLL_LINE_60")
    end

    test.step("Down in the output pane scrolls by one line") do
      test.press(:output, "Down")
      test.expect_visible("SMOKE_SCROLL_LINE_02")
    end

    test.step("Up in the output pane scrolls back by one line") do
      test.press(:output, "Up")
      test.expect_visible("SMOKE_SCROLL_LINE_01")
    end

    test.step("PageDown in the output pane returns to the latest lines") do
      4.times { test.press(:output, "PageDown") }
      test.expect_visible("SMOKE_SCROLL_LINE_60")
    end

    test.step("Alt+PageUp in the input pane reaches the first lines") do
      4.times { test.press(:input, "M-PageUp") }
      test.expect_visible("SMOKE_SCROLL_LINE_01")
      test.expect_output_without("SMOKE_SCROLL_LINE_60")
    end

    test.step("Alt+Down in the input pane scrolls by one line") do
      test.press(:input, "M-Down")
      test.expect_visible("SMOKE_SCROLL_LINE_02")
    end

    test.step("Alt+Up in the input pane scrolls back by one line") do
      test.press(:input, "M-Up")
      test.expect_visible("SMOKE_SCROLL_LINE_01")
    end

    test.step("Alt+PageDown in the input pane returns to the latest lines") do
      4.times { test.press(:input, "M-PageDown") }
      test.expect_visible("SMOKE_SCROLL_LINE_60")
    end

    test.step("Alt+Z from Input zooms Output") do
      test.press(:input, "M-z")
      test.expect_zoomed(true)
    end

    test.step("Alt+Z from Output restores the split") do
      test.press(:output, "M-z")
      test.expect_zoomed(false)
    end

    test.step("Alt+Z from Output zooms Output") do
      test.press(:output, "M-z")
      test.expect_zoomed(true)
    end

    test.step("Alt+Z from Input restores the split") do
      test.press(:input, "M-z")
      test.expect_zoomed(false)
    end

    test.step("Leave the smoke-test session running") do
      raise "The smoke-test Tmux session disappeared." unless test.session_exists?(test.session_name)
    end
  end
rescue ex
  STDERR.puts "tmux.repl smoke test: #{ex.class}: #{ex.message}"
  exit 1
end
