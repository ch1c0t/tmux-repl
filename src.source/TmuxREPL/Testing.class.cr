DEFAULT_TIMEOUT = 8.seconds
START_TIMEOUT = 8.seconds
HOST_STOP_TIMEOUT = 5.seconds

@server : Tmux::Server
@origin_session : Tmux::Session
@origin_session_name : String
@session_name : String?
@input_pane : Tmux::Pane?
@output_pane : Tmux::Pane?
@cleanup : Symbol
@restore_client : Bool
@step_delay : Time::Span
@started_at : Time
@stage = "initialize"
@sequence = 0
@definition : Definition?
@definition_host_result : Channel(String)?
@host_process : Process?
@host_exit : Channel(Process::Status)?
@host_status : Process::Status?
@host_log : File?
@host_log_path : String?
@event_channel : Channel(Event)?
@failure : Exception?
@session_cleaned = false
@report = [] of NamedTuple(
  name: String,
  passed: Bool,
  duration_ms: Float64,
  details: String
)

struct Configuration
  getter focus : Bool
  getter cleanup : Symbol
  getter restore_client : Bool
  getter step_delay : Time::Span
  getter timeout : Time::Span
  getter start_timeout : Time::Span
  getter host_stop_timeout : Time::Span

  def initialize(
    @focus : Bool,
    @cleanup : Symbol,
    @restore_client : Bool,
    @step_delay : Time::Span,
    @timeout : Time::Span,
    @start_timeout : Time::Span,
    @host_stop_timeout : Time::Span
  )
    unless @cleanup == :always || @cleanup == :never || @cleanup == :on_failure
      raise ArgumentError.new("cleanup must be always, never, or on_failure; got #{@cleanup.inspect}")
    end

    if @focus && @cleanup != :never && !@restore_client
      raise ArgumentError.new("restore_client must be enabled when a focused test session may be cleaned up")
    end
  end

  def self.from_env(
    name : String,
    focus : Bool,
    cleanup : Symbol,
    restore_client : Bool,
    step_delay : Time::Span,
    timeout : Time::Span,
    start_timeout : Time::Span,
    host_stop_timeout : Time::Span
  ) : self
    new(
      boolean(name, "FOCUS", focus),
      cleanup_policy(name, cleanup),
      boolean(name, "RESTORE_CLIENT", restore_client),
      duration(name, "DELAY", step_delay),
      duration(name, "TIMEOUT", timeout),
      duration(name, "START_TIMEOUT", start_timeout),
      duration(name, "HOST_STOP_TIMEOUT", host_stop_timeout)
    )
  end

  private def self.environment_value(name : String, setting : String) : String?
    scenario = (name.split('.').last? || name).gsub(/[^a-zA-Z0-9]/, "_").upcase
    full_name = name.gsub(/[^a-zA-Z0-9]/, "_").upcase

    ENV["TMUX_REPL_TEST_#{scenario}_#{setting}"]? ||
      ENV["TMUX_REPL_TEST_#{full_name}_#{setting}"]? ||
      ENV["TMUX_REPL_TEST_#{setting}"]?
  end

  private def self.boolean(name : String, setting : String, default : Bool) : Bool
    value = environment_value(name, setting)
    return default unless value

    case value.downcase
    when "1", "true", "yes", "on"
      true
    when "0", "false", "no", "off"
      false
    else
      raise ArgumentError.new("Invalid boolean for TMUX_REPL_TEST_#{setting}: #{value.inspect}")
    end
  end

  private def self.cleanup_policy(name : String, default : Symbol) : Symbol
    value = environment_value(name, "CLEANUP")
    return default unless value

    case value.downcase
    when "always"
      :always
    when "never"
      :never
    when "on_failure"
      :on_failure
    else
      raise ArgumentError.new("Invalid cleanup policy for TMUX_REPL_TEST_CLEANUP: #{value.inspect}")
    end
  end

  private def self.duration(name : String, setting : String, default : Time::Span) : Time::Span
    value = environment_value(name, setting)
    return default unless value

    seconds = value.to_f?
    unless seconds && seconds >= 0
      raise ArgumentError.new("Expected non-negative seconds for TMUX_REPL_TEST_#{setting}, got #{value.inspect}")
    end

    seconds.seconds
  end
end

struct Event
  getter type : String
  getter sequence : Int64
  getter chunk : String?
  getter status : Int32?
  getter clean_output : String?

  def initialize(
    @type : String,
    @sequence : Int64,
    @chunk : String?,
    @status : Int32?,
    @clean_output : String?
  )
  end
end

class CommandResult
  getter sequence : Int32
  getter command : String
  getter status : Int32?

  @output = ""
  @completed = false

  def initialize(
    @runner : Testing,
    @sequence : Int32,
    @command : String
  )
    @status = nil
  end

  # Wait for protocol output first, then verify that the Output pane rendered it.
  def expect_output(
    *expected : String,
    timeout : Time::Span? = nil
  ) : self
    expected_items = expected.to_a
    timeout = timeout || @runner.timeout
    deadline = Time.instant + timeout

    until expected_items.all? { |item| output.includes?(item) } || @completed
      remaining = deadline - Time.instant
      raise "Timed out waiting for command ##{@sequence} output; received: #{output.inspect}" if remaining <= Time::Span.zero
      @runner.receive_command_event(self, remaining)
    end

    missing = expected_items.reject { |item| output.includes?(item) }
    raise "Command ##{@sequence} completed without expected output #{missing.map(&.inspect).join(", ")}; received: #{output.inspect}" unless missing.empty?

    @runner.expect_command_output(@sequence, expected_items, timeout)
    self
  end

  def expect_status(
    status : Int32,
    timeout : Time::Span? = nil
  ) : self
    timeout = timeout || @runner.timeout
    wait_for_completion(timeout)
    raise "Command ##{@sequence} exited with status #{@status.inspect}, expected #{status}." unless @status == status

    @runner.expect_command_status(@sequence, status, timeout)
    self
  end

  def expect_complete(
    timeout : Time::Span? = nil
  ) : self
    timeout = timeout || @runner.timeout
    wait_for_completion(timeout)
    @runner.expect_command_complete(@sequence, timeout)
    self
  end

  def output : String
    @output
  end

  def accept(event : Event) : Nil
    if event.type == "output"
      @output += event.chunk.not_nil! if event.chunk
    elsif event.type == "complete"
      @status = event.status
      @completed = true
      if @output.empty? && (clean = event.clean_output)
        @output = clean
      end
    end
  end

  private def wait_for_completion(timeout : Time::Span) : Nil
    deadline = Time.instant + timeout
    until @completed
      remaining = deadline - Time.instant
      raise "Timed out waiting for command ##{@sequence} completion." if remaining <= Time::Span.zero
      @runner.receive_command_event(self, remaining)
    end
  end
end

def self.run(
  name : String,
  cleanup : Symbol = :never,
  focus : Bool = true,
  restore_client : Bool = true,
  step_delay : Time::Span = 0.seconds,
  timeout : Time::Span = DEFAULT_TIMEOUT,
  start_timeout : Time::Span = START_TIMEOUT,
  host_stop_timeout : Time::Span = HOST_STOP_TIMEOUT,
  &scenario : Testing ->
) : Nil
  configuration = Configuration.from_env(
    name,
    focus,
    cleanup,
    restore_client,
    step_delay,
    timeout,
    start_timeout,
    host_stop_timeout
  )
  runner = new(name, configuration)
  runner.run { yield runner }
end

def initialize(
  @name : String,
  configuration : Configuration
)
  unless ENV["TMUX"]? && ENV["TMUX_PANE"]?
    raise "Run this smoke test from inside the Tmux session to return to."
  end

  @configuration = configuration
  @cleanup = configuration.cleanup
  @focus = configuration.focus
  @restore_client = configuration.restore_client
  @step_delay = configuration.step_delay
  @timeout = configuration.timeout
  @start_timeout = configuration.start_timeout
  @host_stop_timeout = configuration.host_stop_timeout

  @server = Tmux::Server.from_env
  @origin_session = Tmux::Session.from_env
  @origin_session_name = @origin_session.session_name
  @started_at = Time.utc
end

getter timeout : Time::Span

def run(&scenario : Testing ->) : Nil
  begin
    yield self
  rescue ex
    @failure = ex
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
    finish
  end

  report_path = write_machine_report
  print_report(report_path)
  raise @failure.not_nil! if @failure
end

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

def step(name : String, &block : -> T) : Nil forall T
  started_at = Time.instant
  @stage = name

  begin
    yield
    @report << {
      name: name,
      passed: true,
      duration_ms: (Time.instant - started_at).total_milliseconds,
      details: "",
    }
    sleep @step_delay if @step_delay.total_nanoseconds > 0
  rescue ex
    @report << {
      name: name,
      passed: false,
      duration_ms: (Time.instant - started_at).total_milliseconds,
      details: "#{ex.class}: #{ex.message}",
    }
    raise ex
  end
end

def submit(command : String) : CommandResult
  @sequence += 1
  input_pane.send_keys(command, literal: true)
  CommandResult.new(self, @sequence, command)
end

def press(pane : Symbol, key : String) : Nil
  target = case pane
           when :input
             input_pane
           when :output
             output_pane
           else
             raise ArgumentError.new("pane must be :input or :output, got #{pane.inspect}")
           end
  target.send_keys(key, enter: false)
end

def expect_visible(
  *expected : String,
  timeout : Time::Span? = nil
) : Nil
  expect_visible_items(expected.to_a, timeout || @timeout)
end

def expect_visible_items(
  expected_items : Array(String),
  timeout : Time::Span = DEFAULT_TIMEOUT
) : Nil
  last_text = ""
  found = wait_until(timeout) do
    last_text = current_output
    expected_items.all? { |item| last_text.includes?(item) }
  end
  return if found

  missing = expected_items.reject { |item| last_text.includes?(item) }
  raise "Timed out waiting for the Output pane to show #{missing.map(&.inspect).join(", ")}.\n#{last_text}"
end

def expect_output_without(marker : String) : Nil
  text = current_output
  raise "Output pane still contains #{marker.inspect}.\n#{text}" if text.includes?(marker)
end

def expect_selected_input(sequence : Int32) : Nil
  expect_visible("INPUT ##{sequence}")
end

def expect_zoomed(expected : Bool) : Nil
  found = wait_until do
    zoomed = output_pane.display_message("\#{window_zoomed_flag}") == "1"
    zoomed == expected && (!expected || output_pane.active?)
  end
  return if found

  actual = output_pane.display_message("\#{window_zoomed_flag}") == "1"
  raise "Expected Output pane zoomed=#{expected}, got #{actual}."
end

def receive_command_event(result : CommandResult, timeout : Time::Span) : Nil
  events = @event_channel || raise "The REPL event consumer has not started."

  if host_exit = @host_exit
    select
    when event = events.receive
      result.accept(event) if event.sequence == result.sequence.to_i64
    when status = host_exit.receive
      @host_status = status
      raise_host_exit!(status)
    when timeout(timeout)
      raise "Timed out waiting for a protocol event for command ##{result.sequence}."
    end
  else
    select
    when event = events.receive
      result.accept(event) if event.sequence == result.sequence.to_i64
    when timeout(timeout)
      raise "Timed out waiting for a protocol event for command ##{result.sequence}."
    end
  end
end

def expect_command_output(
  sequence : Int32,
  expected : Array(String),
  timeout : Time::Span
) : Nil
  expect_visible_items(["INPUT ##{sequence}"] + expected, timeout)
end

def expect_command_status(
  sequence : Int32,
  status : Int32,
  timeout : Time::Span
) : Nil
  expect_visible("INPUT ##{sequence}", "[exit status: #{status}]", timeout: timeout)
end

def expect_command_complete(
  sequence : Int32,
  timeout : Time::Span
) : Nil
  last_text = ""
  found = wait_until(timeout) do
    last_text = current_output
    last_text.includes?("INPUT ##{sequence}") && last_text.includes?("[exit status:")
  end
  return if found

  raise "Timed out waiting for command ##{sequence} to complete.\n#{last_text}"
end

def current_output : String
  pane_text(output_pane)
end

private def start_event_consumer : Nil
  name = @session_name || raise "The REPL session has not been identified."
  queue = TmuxREPL.stream_queue(
    Global.amqp_channel,
    TmuxREPL.events_queue_name(name)
  )
  events = Channel(Event).new(256)
  @event_channel = events

  queue.subscribe(
    no_ack: false,
    block: false,
    args: AMQ::Protocol::Table.new(
      {"x-stream-offset" => "next"} of String => AMQ::Protocol::Field
    )
  ) do |message|
    begin
      data = JSON.parse(message.body_io.to_s)
      if data["session"]?.try(&.as_s) == name
        sequence = data["sequence"]?.try(&.as_i64) || 0_i64
        status = data["status"]?.try { |value| value.as_i64.to_i32 }
        chunk = data["chunk"]?.try(&.as_s)
        clean_output = data["clean_output"]?.try(&.as_s)
        events.send(Event.new(data["type"].as_s, sequence, chunk, status, clean_output))
      end
      message.ack
    rescue ex
      STDERR.puts "tmux.repl.testing: could not read event: #{ex.class}: #{ex.message}"
      begin
        message.reject(requeue: false)
      rescue
      end
    end
  end
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

private def input_pane : Tmux::Pane
  @input_pane || raise "Input pane is not available."
end

private def output_pane : Tmux::Pane
  @output_pane || raise "Output pane is not available."
end

private def pane_text(pane : Tmux::Pane) : String
  pane.capture_pane(join_wrapped: true).join("\n")
end

private def wait_until(
  timeout : Time::Span? = nil,
  interval : Time::Span = 25.milliseconds,
  &condition : -> Bool
) : Bool
  deadline = Time.instant + (timeout || @timeout)
  while Time.instant < deadline
    return true if yield
    sleep interval
  end
  yield
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

private def finish : Nil
  if @output_pane
    cleanup_step("Restore Output pane zoom") { restore_output_zoom }
  end

  if @restore_client && @focus
    cleanup_step("Return to original session") { return_to_origin }
  end

  should_cleanup = @cleanup == :always || (@cleanup == :on_failure && !@failure.nil?)
  if should_cleanup && @session_name
    cleanup_step("Clean up REPL session") { cleanup_session }
  end
end

private def cleanup_step(name : String, &block : ->) : Nil
  started_at = Time.instant
  begin
    yield
    @report << {
      name: name,
      passed: true,
      duration_ms: (Time.instant - started_at).total_milliseconds,
      details: "",
    }
  rescue ex
    @report << {
      name: name,
      passed: false,
      duration_ms: (Time.instant - started_at).total_milliseconds,
      details: "#{ex.class}: #{ex.message}",
    }
    @failure ||= ex
  end
end

private def restore_output_zoom : Nil
  pane = @output_pane
  return unless pane
  return unless pane.display_message("\#{window_zoomed_flag}") == "1"

  pane.select
  pane.run!("resize-pane", "-Z", "-t", pane.pane_id)
end

private def return_to_origin : Nil
  @origin_session.switch_client
  restored = wait_until { current_client_session_name == @origin_session_name }
  raise "The Tmux client did not return to #{@origin_session_name.inspect}." unless restored
end

private def cleanup_session : Nil
  name = @session_name
  failure : Exception? = nil

  if definition = @definition
    begin
      definition.stop
    rescue ex
      failure = ex
      @server.cmd("kill-session", "-t", name.not_nil!) if name
    end

    begin
      wait_for_custom_host
    rescue ex
      failure ||= ex
    end
  else
    if name
      begin
        Session.new(name).stop
      rescue ex
        failure = ex
        @server.cmd("kill-session", "-t", name)
      end
    end

    begin
      stop_host_process
    rescue ex
      failure ||= ex
    end
  end

  if name
    removed = wait_until(@host_stop_timeout) do
      !@server.cmd("has-session", "-t", name).success?
    end
    failure ||= Exception.new("Tmux session #{name.inspect} was not removed.") unless removed
  end

  raise failure.not_nil! if failure
  @session_cleaned = true
end

private def wait_for_custom_host : Nil
  result = @definition_host_result || return
  message = ""

  select
  when value = result.receive
    message = value
  when timeout(@host_stop_timeout)
    raise "Timed out waiting for the in-process custom command host to stop."
  end

  raise "Custom command host failed: #{message}" unless message.empty?
end

private def custom_session_ready?(name : String) : Bool
  return false unless @server.cmd("has-session", "-t", name).success?

  state = State.new(name)
  return false unless File.exists?(state.path("input.pid"))
  return false unless File.exists?(state.path("output.pid"))

  @server.session(name).active_window.panes.size == 2
end

private def host_exit_status(timeout : Time::Span) : Process::Status?
  return @host_status if @host_status

  channel = @host_exit || return nil
  select
  when status = channel.receive
    @host_status = status
  when timeout(timeout)
  end

  @host_status
end

private def raise_host_exit! : Nil
  status = host_exit_status(0.seconds)
  raise_host_exit!(status) if status
end

private def raise_host_exit!(status : Process::Status) : NoReturn
  close_host_log
  raise "Custom REPL host process exited with status #{status.exit_code}. #{host_diagnostics}"
end

private def stop_host_process : Nil
  process = @host_process
  unless process
    close_host_log
    return
  end

  status = host_exit_status(@host_stop_timeout)
  unless status
    begin
      process.terminate
    rescue
    end
    status = host_exit_status(@host_stop_timeout)
  end
  unless status
    begin
      process.terminate(graceful: false)
    rescue
    end
    status = host_exit_status(@host_stop_timeout)
  end

  unless status
    raise "Timed out waiting for custom REPL host process #{process.pid} to exit after termination. #{host_diagnostics}"
  end

  close_host_log
  raise "Custom REPL host exited with status #{status.exit_code}. #{host_diagnostics}" unless status.success?
end

private def close_host_log : Nil
  @host_log.try &.close
  @host_log = nil
end

private def host_diagnostics : String
  path = @host_log_path
  return "Host log unavailable." unless path

  contents = File.exists?(path) ? File.read(path).strip : ""
  contents.empty? ? "Host log: #{path}" : "Host log: #{path}\n#{contents}"
rescue ex
  "Could not read custom host log: #{ex.message}"
end

private def write_machine_report : String
  passed = @report.all? { |check| check[:passed] }
  finished_at = Time.utc.to_unix_ms
  directory = State.smoke_tests_path
  FileUtils.mkdir_p(directory)

  path = File.join(directory, "smoke-test-#{@started_at.to_unix_ms}-#{Process.pid}.json")
  temporary_path = "#{path}.tmp"

  contents = JSON.build(indent: "  ") do |json|
    json.object do
      json.field "schema_version", 1
      json.field "test", @name
      json.field "status", passed ? "passed" : "failed"
      json.field "exit_code", passed ? 0 : 1
      json.field "started_at_unix_ms", @started_at.to_unix_ms
      json.field "finished_at_unix_ms", finished_at
      json.field "original_session", @origin_session_name
      json.field "smoke_test_session", @session_name
      json.field "custom_host_pid", @host_process.try(&.pid)
      json.field "custom_host_log", @host_log_path
      json.field "session_cleaned", @session_cleaned
      json.field "configuration" do
        json.object do
          json.field "focus", @focus
          json.field "cleanup", @cleanup.to_s
          json.field "restore_client", @restore_client
          json.field "step_delay_seconds", @step_delay.total_seconds
          json.field "timeout_seconds", @timeout.total_seconds
          json.field "start_timeout_seconds", @start_timeout.total_seconds
          json.field "host_stop_timeout_seconds", @host_stop_timeout.total_seconds
        end
      end
      json.field "checks" do
        json.array do
          @report.each do |check|
            json.object do
              json.field "name", check[:name]
              json.field "status", check[:passed] ? "passed" : "failed"
              json.field "duration_ms", check[:duration_ms]
              json.field "details", check[:details]
            end
          end
        end
      end
    end
  end

  File.write(temporary_path, contents + "\n")
  File.rename(temporary_path, path)
  path
end

private def print_report(machine_report_path : String) : Nil
  puts
  puts "#{@name} smoke test"
  puts "=" * 72
  puts "Original session: #{@origin_session_name}"
  puts "Smoke-test session: #{@session_name || "(not created)"}"
  puts

  @report.each do |check|
    marker = check[:passed] ? "\e[32mPASS\e[0m" : "\e[31mFAIL\e[0m"
    duration = "#{check[:duration_ms].round(0)} ms"
    details = check[:details]
    summary = details.empty? ? duration : "#{duration}; #{details}"
    puts "#{marker}  #{check[:name]} (#{summary})"
  end

  puts
  if name = @session_name
    if @session_cleaned
      puts "The temporary smoke-test session was cleaned up: #{name}"
    else
      puts "The smoke-test session was left open: #{name}"
      puts "Return to it with: tmux switch-client -t '#{name}'"
    end
  else
    puts "No smoke-test session was created."
  end
  puts "Machine-readable report: #{machine_report_path}"
end
