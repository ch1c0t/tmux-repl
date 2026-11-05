module LavinMQProcess
  module Selection
    private def verify_selection : Nil
      submit_and_expect("printf 'FIRST_REPL_OUTPUT\\n'", 1, "FIRST_REPL_OUTPUT")
      submit_and_expect("printf 'SECOND_REPL_OUTPUT\\n'", 2, "SECOND_REPL_OUTPUT")

      input_pane.send_keys(":prev", literal: true)
      expect_output("INPUT #1", "FIRST_REPL_OUTPUT", "[exit status: 0]")
      expect_output_without("SECOND_REPL_OUTPUT")

      input_pane.send_keys(":next", literal: true)
      expect_output("INPUT #2", "SECOND_REPL_OUTPUT", "[exit status: 0]")

      # Ctrl+Up/Down remain the primary input-selection keys.
      input_pane.send_keys("C-Up", enter: false)
      expect_output("INPUT #1", "FIRST_REPL_OUTPUT", "[exit status: 0]")
      expect_output_without("SECOND_REPL_OUTPUT")

      input_pane.send_keys("C-Down", enter: false)
      expect_output("INPUT #2", "SECOND_REPL_OUTPUT", "[exit status: 0]")

      # Alt+K/J are aliases, translated for Reply's key parser.
      input_pane.send_keys("M-k", enter: false)
      expect_output("INPUT #1", "FIRST_REPL_OUTPUT", "[exit status: 0]")
      expect_output_without("SECOND_REPL_OUTPUT")

      input_pane.send_keys("M-j", enter: false)
      expect_output("INPUT #2", "SECOND_REPL_OUTPUT", "[exit status: 0]")

      input_pane.send_keys(":list", literal: true)
      expect_input("#1: printf", "* #2: printf")

      input_pane.send_keys(":help", literal: true)
      expect_input(
        ":select ID", ":prev", ":next", ":list",
        "Ctrl+G", "Ctrl+Up", "Ctrl+Down", "Alt+K", "Alt+J", "Alt+Z"
      )

      input_pane.send_keys(":select 1", literal: true)
      expect_output("INPUT #1", "FIRST_REPL_OUTPUT", "[exit status: 0]")
      expect_output_without("SECOND_REPL_OUTPUT")
    end

    private def submit_and_expect(command : String, sequence : Int32, output : String) : Nil
      input_pane.send_keys(command, literal: true)
      expect_output(output, "[exit status: 0]")
      expect_input("[input ##{sequence}] submitted", "$:002>")
    end
  end
end
