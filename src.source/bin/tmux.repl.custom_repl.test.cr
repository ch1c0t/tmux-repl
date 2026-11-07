require "../tmux_repl"

session_name = "tmux-repl-custom-test-#{Process.pid}-#{Time.utc.to_unix_ms}"

definition = TmuxREPL.define(session_name) do |repl|
  repl.on_command("ocr") do |context, arguments|
    raise ArgumentError.new("Usage: ocr") unless arguments.empty?
    context.puts("SCREEN OCR: fixture display is ready")
  end

  repl.on_command("key") do |context, arguments|
    unless arguments.size == 2 && {"press", "release"}.includes?(arguments[0])
      raise ArgumentError.new("Usage: key press|release KEY")
    end

    context.puts("KEY EVENT: #{arguments[0]} #{arguments[1]}")
  end

  repl.on_command("echo") do |context, arguments|
    context.puts(arguments.join(" "))
  end

  repl.on_command("fail") do |_context, _arguments|
    raise "fixture failure"
  end
end

begin
  TmuxREPL::Testing.run(
    "tmux.repl.custom_repl",
    cleanup: :always,
    focus: true,
    restore_client: true
  ) do |test|
    test.step("Start custom REPL in the application process") do
      test.start_custom(definition)
    end

    test.step("Execute the OCR handler") do
      command = test.submit("ocr")
      command.expect_output("SCREEN OCR: fixture display is ready").expect_status(0)
    end

    test.step("Execute a key handler") do
      command = test.submit("key press Escape")
      command.expect_output("KEY EVENT: press Escape").expect_status(0)
    end

    test.step("Preserve quoted command arguments") do
      command = test.submit(%(echo "hello world"))
      command.expect_output("hello world").expect_status(0)
    end

    test.step("Complete unknown commands with status 127") do
      command = test.submit("missing")
      command.expect_output("Unknown command: missing").expect_status(127)
    end

    test.step("Display handler failures with status 1") do
      command = test.submit("fail")
      command.expect_output("Error: fixture failure").expect_status(1)
    end
  end
rescue ex
  STDERR.puts "tmux.repl.custom_repl.test: #{ex.class}: #{ex.message}"
  exit 1
end
