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

class CustomREPLSmokeTest
  TIMEOUT = 8.seconds

  @server : Tmux::Server
  @session_name : String
  @process : Process?
  @input_pane : Tmux::Pane?
  @output_pane : Tmux::Pane?
  @checks = 0

  def initialize
    unless ENV["TMUX"]? && ENV["TMUX_PANE"]?
      raise "Run tmux.repl.custom_repl.test from inside the Tmux session to return to."
    end

    @server = Tmux::Server.from_env
    @session_name = "tmux-repl-custom-test-#{Process.pid}-#{Time.utc.to_unix_ms}"
    @process = nil
    @input_pane = nil
    @output_pane = nil
  end

  def run : Nil
    begin
      start_fixture
      attach_panes
      check(
        "ocr",
        ["INPUT #1", "SCREEN OCR: fixture display is ready", "[exit status: 0]"]
      )
      check(
        "key press Escape",
        ["INPUT #2", "KEY EVENT: press Escape", "[exit status: 0]"]
      )
      check(
        %(echo "hello world"),
        ["INPUT #3", "hello world", "[exit status: 0]"]
      )
      check(
        "missing",
        ["INPUT #4", "Unknown command: missing", "[exit status: 127]"]
      )
      check(
        "fail",
        ["INPUT #5", "Error: fixture failure", "[exit status: 1]"]
      )
    ensure
      cleanup
    end

    puts
    puts "tmux.repl.custom_repl smoke test: #{@checks} checks passed."
  end

  private def start_fixture : Nil
    executable = File.join(File.dirname(File.expand_path(PROGRAM_NAME)), "tmux.repl.custom_repl")
    raise "Missing #{executable}. Build the executables first with shards build." unless File::Info.executable?(executable)

    environment = {} of String => String?
    ENV.each { |key, value| environment[key] = value }
    environment["TMUX_REPL_SESSION"] = @session_name

    @process = Process.new(
      executable,
      [] of String,
      env: environment,
      input: Process::Redirect::Close,
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )

    session : Tmux::Session? = nil
    ready = wait_until do
      session = @server.sessions.find { |candidate| candidate.session_name == @session_name }
      !session.nil?
    end
    raise "Custom REPL session #{@session_name.inspect} did not start." unless ready
  end

  private def attach_panes : Nil
    session = @server.session(@session_name)
    panes = session.active_window.panes
    raise "Expected two panes, found #{panes.size}." unless panes.size == 2

    @input_pane = panes[0]
    @output_pane = panes[1]
    @checks += 1
    puts "PASS  Custom host starts with two panes"
  end

  private def check(command : String, expected : Array(String)) : Nil
    input_pane.send_keys(command, literal: true)
    last_text = ""
    found = wait_until do
      last_text = pane_text(output_pane)
      expected.all? { |text| last_text.includes?(text) }
    end
    unless found
      missing = expected.reject { |text| last_text.includes?(text) }
      raise "Command #{command.inspect} did not produce #{missing.map(&.inspect).join(", ")}.\n#{last_text}"
    end

    @checks += 1
    puts "PASS  #{command}"
  end

  private def wait_until(&condition : -> Bool) : Bool
    deadline = Time.instant + TIMEOUT
    while Time.instant < deadline
      return true if yield
      sleep 25.milliseconds
    end
    yield
  end

  private def pane_text(pane : Tmux::Pane) : String
    pane.capture_pane(join_wrapped: true).join("\n")
  end

  private def input_pane : Tmux::Pane
    @input_pane || raise "Input pane is not available."
  end

  private def output_pane : Tmux::Pane
    @output_pane || raise "Output pane is not available."
  end

  private def cleanup : Nil
    @server.cmd("kill-session", "-t", @session_name) if @server.cmd("has-session", "-t", @session_name).success?
    if process = @process
      status = process.wait
      raise "Custom REPL host exited with status #{status.exit_code}." unless status.success?
    end
  rescue ex
    STDERR.puts "tmux.repl.custom_repl.test cleanup: #{ex.message}"
  end
end

begin
  CustomREPLSmokeTest.new.run
rescue ex
  STDERR.puts "tmux.repl.custom_repl.test: #{ex.class}: #{ex.message}"
  exit 1
end
