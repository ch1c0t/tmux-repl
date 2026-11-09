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

class CustomREPLScenario < TmuxREPL::Testing::Scenario
  @custom_session_name : String

  def initialize(name : String, configuration : TmuxREPL::Testing::Configuration)
    super(name, configuration)
    @custom_session_name = "tmux-repl-custom-test-#{Process.pid}-#{Time.utc.to_unix_ms}"
  end

  private def custom_session_name : String
    @custom_session_name
  end

  step "Start custom REPL in a separate application process" do
    start_host(
      "./bin/tmux.repl.custom_repl",
      ["start", custom_session_name],
      custom_session_name
    )
  end

  step "Execute the OCR handler" do
    submit("ocr").expect_output("SCREEN OCR: fixture display is ready").expect_status(0)
  end

  step "Execute a key handler" do
    submit("key press Escape").expect_output("KEY EVENT: press Escape").expect_status(0)
  end

  step "Preserve quoted command arguments" do
    submit(%(echo "hello world")).expect_output("hello world").expect_status(0)
  end

  step "Complete unknown commands with status 127" do
    submit("missing").expect_output("Unknown command: missing").expect_status(127)
  end

  step "Display handler failures with status 1" do
    submit("fail").expect_output("Error: fixture failure").expect_status(1)
  end
end

begin
  TmuxREPL::Testing.run(
    CustomREPLScenario,
    name: "tmux.repl.custom_repl",
    cleanup: :always,
    focus: true,
    restore_client: true
  )
rescue ex
  STDERR.puts "tmux.repl.custom_repl.test: #{ex.class}: #{ex.message}"
  exit 1
end
