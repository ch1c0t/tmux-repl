def session_name : String
  @session_name || raise "The REPL session has not been started."
end

def session_exists?(name : String) : Bool
  @server.cmd("has-session", "-t", name).success?
end

# Start the regular CLI and identify the single new session it creates.
def start_cli(
  executable : String,
  arguments : Array(String) = ["start"]
) : self
  raise "A REPL session has already been started." if @session_name
  raise "Missing #{executable}. Build the executables first with shards build." unless File::Info.executable?(executable)

  existing_session_ids = @server.sessions.map(&.session_id)
  environment = {} of String => String?
  ENV.each { |key, value| environment[key] = value }
  environment["TMUX_REPL_SESSION"] = nil
  cli_arguments = arguments.dup
  cli_arguments << "--no-focus" unless @focus || cli_arguments.includes?("--no-focus")

  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(
    executable,
    cli_arguments,
    env: environment,
    output: stdout,
    error: stderr
  )
  unless status.success?
    raise "#{executable} #{arguments.join(" ")} failed (#{status.exit_code}).\n#{stdout}\n#{stderr}"
  end

  created : Tmux::Session? = nil
  found = wait_until(@start_timeout) do
    candidates = @server.sessions.select do |session|
      !existing_session_ids.includes?(session.session_id) &&
        session.session_name.starts_with?("#{@origin_session_name}|repl-")
    end

    raise "Expected one new REPL session, found #{candidates.size}." if candidates.size > 1

    created = candidates.first?
    !created.nil?
  end

  unless found
    raise "Could not find the session created by #{executable} #{arguments.join(" ")}."
  end

  @session_name = created.not_nil!.session_name
  attach_session
  ensure_foreground! if @focus
  self
end


# Start a custom REPL application in a separate process. The expected session
# name is explicit, so discovery never depends on a session-name prefix.
def start_host(
  executable : String,
  arguments : Array(String),
  expected_session_name : String
) : self
  raise "A REPL session has already been started." if @session_name
  raise "Missing #{executable}. Build the executables first with shards build." unless File::Info.executable?(executable)
  raise "Custom REPL tests require cleanup: :always." unless @cleanup == :always
  if @server.cmd("has-session", "-t", expected_session_name).success?
    raise "Tmux session #{expected_session_name.inspect} already exists."
  end

  @session_name = expected_session_name
  FileUtils.mkdir_p(State.smoke_tests_path)
  @host_log_path = File.join(
    State.smoke_tests_path,
    "custom-host-#{Process.pid}-#{Time.utc.to_unix_ms}.log"
  )
  @host_log = File.open(@host_log_path.not_nil!, "w")

  host_arguments = arguments.dup
  host_arguments << "--no-focus" unless @focus || host_arguments.includes?("--no-focus")

  process = Process.new(
    executable,
    host_arguments,
    env: {"TMUX_REPL_SESSION" => nil},
    input: Process::Redirect::Close,
    output: @host_log.not_nil!,
    error: @host_log.not_nil!
  )
  @host_process = process

  exit_channel = Channel(Process::Status).new(1)
  @host_exit = exit_channel
  spawn do
    exit_channel.send(process.wait)
  end

  ready = wait_until(@start_timeout) do
    raise_host_exit!
    custom_session_ready?(expected_session_name)
  end
  unless ready
    raise "Timed out waiting for custom REPL #{expected_session_name.inspect} to become ready. #{host_diagnostics}"
  end

  attach_session
  ensure_foreground! if @focus
  self
end

# Start a custom REPL in this process so its handlers retain access to
# application-owned objects. Custom test sessions are always temporary.
def start_custom(definition : Definition) : self
  raise "A REPL session has already been started." if @session_name
  raise ArgumentError.new("start_custom requires at least one custom command.") unless definition.custom_commands?
  if @server.cmd("has-session", "-t", definition.name).success?
    raise "Tmux session #{definition.name.inspect} already exists."
  end

  raise "Custom REPL tests require cleanup: :always." unless @cleanup == :always

  definition.start(focus: @focus)
  @definition = definition
  @session_name = definition.name

  host_result = Channel(String).new(1)
  @definition_host_result = host_result
  spawn do
    result = ""
    begin
      definition.serve
    rescue ex
      result = "#{ex.class}: #{ex.message}"
    ensure
      host_result.send(result)
    end
  end

  attach_session
  ensure_foreground! if @focus
  self
end

private def attach_session : Nil
  name = @session_name || raise "The REPL session has not been identified."
  session = @server.session(name)
  panes = session.active_window.panes
  raise "Expected two panes in #{name.inspect}, found #{panes.size}." unless panes.size == 2

  @input_pane = panes[0]
  @output_pane = panes[1]
  start_event_consumer
end

private def ensure_foreground! : Nil
  current = current_client_session_name
  expected = @session_name
  raise "Expected the foreground Tmux session to be #{expected.inspect}, got #{current.inspect}." unless current == expected
end

private def custom_session_ready?(name : String) : Bool
  return false unless @server.cmd("has-session", "-t", name).success?

  state = State.new(name)
  return false unless File.exists?(state.path("input.pid"))
  return false unless File.exists?(state.path("output.pid"))

  @server.session(name).active_window.panes.size == 2
end
