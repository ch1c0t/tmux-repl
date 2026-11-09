require "./tmux.repl.custom_repl.test/*"

VERSION = "0.1.0"

case ARGV.size
when 1
  case ARGV[0]
  when "-v", "version", "--version"
    puts VERSION
    exit
  when "-h", "help", "--help"
    print_help
    exit
  end
end

require "../tmux_repl"

session_name = "tmux-repl-custom-test-#{Process.pid}-#{Time.utc.to_unix_ms}"

begin
  TmuxREPL::Testing.run(
    "tmux.repl.custom_repl",
    cleanup: :always,
    focus: true,
    restore_client: true
  ) do |test|
    test.step("Start custom REPL in a separate application process") do
      test.start_host(
        "./bin/tmux.repl.custom_repl",
        ["start", session_name],
        session_name
      )
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
