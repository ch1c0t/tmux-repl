def run : Nil
  begin
    step("Run ./bin/tmux.repl start") { start_repl }
    step("Find the new session and its two panes") { attach_panes }
    step("Submit the first command") do
      submit_command(1, "printf 'SMOKE_FIRST_OUTPUT\\n'", "SMOKE_FIRST_OUTPUT")
    end
    step("Submit the second command") do
      submit_command(2, "printf 'SMOKE_SECOND_OUTPUT\\n'", "SMOKE_SECOND_OUTPUT")
    end
    step("Ctrl+Up selects the previous output") do
      input_pane.send_keys("C-Up", enter: false)
      expect_output("INPUT #1", "SMOKE_FIRST_OUTPUT")
    end
    step("Ctrl+Down selects the next output") do
      input_pane.send_keys("C-Down", enter: false)
      expect_output("INPUT #2", "SMOKE_SECOND_OUTPUT")
    end
    step("Alt+K selects the previous output") do
      input_pane.send_keys("M-k", enter: false)
      expect_output("INPUT #1", "SMOKE_FIRST_OUTPUT")
    end
    step("Alt+J selects the next output") do
      input_pane.send_keys("M-j", enter: false)
      expect_output("INPUT #2", "SMOKE_SECOND_OUTPUT")
    end
    step("Ctrl+L opens the available-outputs list from the input pane") do
      input_pane.send_keys("C-l", enter: false)
      expect_output("AVAILABLE OUTPUTS (2)", "#1", "#2")
    end
    step("Ctrl+L closes the list from the output pane") do
      output_pane.send_keys("C-l", enter: false)
      expect_output("INPUT #2", "SMOKE_SECOND_OUTPUT")
    end
    step("Submit a command for raw/stripped view testing") do
      command = %(for i in $(seq 1 4); do printf 'SMOKE_STREAM_TICK_%s\\n' "$i" && sleep 0.15; done)
      submit_command(3, command, "SMOKE_STREAM_TICK_4")
    end
    step("Ctrl+G from the input pane switches to raw output") do
      input_pane.send_keys("C-g", enter: false)
      expect_output("[RAW;", "START_MARK_", "END_MARK_")
    end
    step("Ctrl+G from the output pane switches back to stripped output") do
      output_pane.send_keys("C-g", enter: false)
      expect_output("[STRIPPED;", "SMOKE_STREAM_TICK_4")
      expect_output_without("START_MARK_")
      expect_output_without("END_MARK_")
    end
    step("Submit a command with enough lines to scroll") do
      command = %(for i in $(seq 1 60); do printf 'SMOKE_SCROLL_LINE_%02d\\n' "$i"; done)
      submit_command(4, command, "SMOKE_SCROLL_LINE_60")
    end
    step("PageUp in the output pane reaches the first lines") do
      4.times { output_pane.send_keys("PageUp", enter: false) }
      expect_output("SMOKE_SCROLL_LINE_01")
      expect_output_without("SMOKE_SCROLL_LINE_60")
    end
    step("Down in the output pane scrolls by one line") do
      output_pane.send_keys("Down", enter: false)
      expect_output("SMOKE_SCROLL_LINE_02")
    end
    step("Up in the output pane scrolls back by one line") do
      output_pane.send_keys("Up", enter: false)
      expect_output("SMOKE_SCROLL_LINE_01")
    end
    step("PageDown in the output pane returns to the latest lines") do
      4.times { output_pane.send_keys("PageDown", enter: false) }
      expect_output("SMOKE_SCROLL_LINE_60")
    end
    step("Alt+PageUp in the input pane reaches the first lines") do
      4.times { input_pane.send_keys("M-PageUp", enter: false) }
      expect_output("SMOKE_SCROLL_LINE_01")
      expect_output_without("SMOKE_SCROLL_LINE_60")
    end
    step("Alt+Down in the input pane scrolls by one line") do
      input_pane.send_keys("M-Down", enter: false)
      expect_output("SMOKE_SCROLL_LINE_02")
    end
    step("Alt+Up in the input pane scrolls back by one line") do
      input_pane.send_keys("M-Up", enter: false)
      expect_output("SMOKE_SCROLL_LINE_01")
    end
    step("Alt+PageDown in the input pane returns to the latest lines") do
      4.times { input_pane.send_keys("M-PageDown", enter: false) }
      expect_output("SMOKE_SCROLL_LINE_60")
    end
    step("Leave the smoke-test session running") do
      unless @server.cmd("has-session", "-t", repl_session_name).success?
        raise "The smoke-test Tmux session disappeared."
      end
    end
  rescue ex
    last = @report.last?
    unless last && !last[:passed]
      @report << {
        name: "Smoke test",
        passed: false,
        duration_ms: 0.0,
        details: "#{@stage}: #{ex.class}: #{ex.message}",
      }
    end
  ensure
    return_to_origin
  end

  report_path = write_machine_report
  print_report(report_path)
  exit 1 unless @report.all? { |check| check[:passed] }
end
