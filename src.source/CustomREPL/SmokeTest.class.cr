  TIMEOUT = 8.seconds

  @server : Tmux::Server
  @origin_session : Tmux::Session
  @origin_session_name : String
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
    @origin_session = Tmux::Session.from_env
    @origin_session_name = @origin_session.session_name
    @session_name = "tmux-repl-custom-test-#{Process.pid}-#{Time.utc.to_unix_ms}"
    @process = nil
    @input_pane = nil
    @output_pane = nil
  end

  def run : Nil
    failure : Exception? = nil

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
    rescue ex
      failure = ex
    ensure
      begin
        cleanup
      rescue ex
        if failure
          STDERR.puts "tmux.repl.custom_repl.test cleanup: #{ex.message}"
        else
          failure = ex
        end
      end
    end

    raise failure.not_nil! if failure

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

    ready = wait_until do
      session_exists = @server.sessions.any? { |candidate| candidate.session_name == @session_name }
      session_exists && current_client_session_name == @session_name
    end

    unless ready
      current = current_client_session_name || "(unavailable)"
      raise "Custom REPL session #{@session_name.inspect} did not become the foreground session (current client session: #{current.inspect})."
    end
  end

  private def attach_panes : Nil
    ensure_foreground!

    session = @server.session(@session_name)
    panes = session.active_window.panes
    raise "Expected two panes, found #{panes.size}." unless panes.size == 2

    @input_pane = panes[0]
    @output_pane = panes[1]
    @checks += 1
    puts "PASS  Custom REPL session is focused with two panes"
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

    ensure_foreground!
    @checks += 1
    puts "PASS  #{command}"
  end

  private def ensure_foreground! : Nil
    current = current_client_session_name
    raise "Expected the foreground Tmux session to be #{@session_name.inspect}, got #{current.inspect}." unless current == @session_name
  end

  private def current_client_session_name : String?
    output = IO::Memory.new
    status = Process.run(
      "tmux",
      ["display-message", "-p", "\#{client_session}"],
      output: output,
      error: Process::Redirect::Close
    )
    return nil unless status.success?

    output.to_s.strip
  rescue
    nil
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
    errors = [] of String

    begin
      if @server.cmd("has-session", "-t", @session_name).success?
        result = @server.cmd("kill-session", "-t", @session_name)
        unless result.success?
          errors << "Could not kill custom Tmux session #{@session_name.inspect}."
          terminate_host
        end
      end
    rescue ex
      errors << "Could not remove custom Tmux session: #{ex.message}"
      terminate_host
    end

    if process = @process
      begin
        status = process.wait
        errors << "Custom REPL host exited with status #{status.exit_code}." unless status.success?
      rescue ex
        errors << "Could not wait for custom REPL host: #{ex.message}"
      end
    end

    begin
      @origin_session.switch_client
      restored = wait_until { current_client_session_name == @origin_session_name }
      raise "The Tmux client did not return to #{@origin_session_name.inspect}." unless restored

      @checks += 1
      puts "PASS  Return to original session #{@origin_session_name}"
    rescue ex
      errors << "Could not return to original Tmux session: #{ex.message}"
    end

    raise errors.join("\n") unless errors.empty?
  end

  private def terminate_host : Nil
    if process = @process
      Process.signal(Signal::TERM, process.pid)
    end
  rescue
  end
