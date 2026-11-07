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
@host_result : Channel(String)?
@event_channel : Channel(Event)?
@failure : Exception?
@report = [] of NamedTuple(
  name: String,
  passed: Bool,
  duration_ms: Float64,
  details: String
)

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

  @output = String::Builder.new
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
    timeout : Time::Span = Testing::DEFAULT_TIMEOUT
  ) : self
    expected_items = expected.to_a
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
    timeout : Time::Span = Testing::DEFAULT_TIMEOUT
  ) : self
    wait_for_completion(timeout)
    raise "Command ##{@sequence} exited with status #{@status.inspect}, expected #{status}." unless @status == status

    @runner.expect_command_status(@sequence, status, timeout)
    self
  end

  def expect_complete(
    timeout : Time::Span = Testing::DEFAULT_TIMEOUT
  ) : self
    wait_for_completion(timeout)
    @runner.expect_command_complete(@sequence, timeout)
    self
  end

  def output : String
    @output.to_s
  end

  def accept(event : Event) : Nil
    if event.type == "output"
      @output << event.chunk.not_nil! if event.chunk
    elsif event.type == "complete"
      @status = event.status
      @completed = true
      if output.empty? && (clean = event.clean_output)
        @output << clean
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
  restore_client : Bool = true,
  step_delay : Time::Span = 0.seconds,
  &scenario : Testing ->
) : Nil
  runner = new(name, cleanup, restore_client, step_delay)
  runner.run { yield runner }
end

def initialize(
  @name : String,
  @cleanup : Symbol = :never,
  @restore_client : Bool = true,
  @step_delay : Time::Span = 0.seconds
)
  unless @cleanup == :always || @cleanup == :never
    raise ArgumentError.new("cleanup must be :always or :never, got #{@cleanup.inspect}")
  end

  unless ENV["TMUX"]? && ENV["TMUX_PANE"]?
    raise "Run this smoke test from inside the Tmux session to return to."
  end

  @server = Tmux::Server.from_env
  @origin_session = Tmux::Session.from_env
  @origin_session_name = @origin_session.session_name
  @started_at = Time.utc
end

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

  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(
    executable,
    arguments,
    env: environment,
    output: stdout,
    error: stderr
  )
  unless status.success?
    raise "#{executable} #{arguments.join(" ")} failed (#{status.exit_code}).\n#{stdout}\n#{stderr}"
  end

  created : Tmux::Session? = nil
  found = wait_until(START_TIMEOUT) do
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
  ensure_foreground!
  self
end

# Start a custom REPL in this process so its handlers retain access to
# application-owned objects. Custom test sessions are always temporary.
def start_custom(definition : Definition) : self
  raise "A REPL session has already been started." if @session_name
  raise "start_custom requires cleanup: :always." unless @cleanup == :always
  raise ArgumentError.new("start_custom requires at least one custom command.") unless definition.custom_commands?
  if @server.cmd("has-session", "-t", definition.name).success?
    raise "Tmux session #{definition.name.inspect} already exists."
  end

  definition.start
  @definition = definition
  @session_name = definition.name

  host_result = Channel(String).new(1)
  @host_result = host_result
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
  ensure_foreground!
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
  timeout : Time::Span = DEFAULT_TIMEOUT
) : Nil
  expect_visible_items(expected.to_a, timeout)
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

  select
  when event = events.receive
    result.accept(event) if event.sequence == result.sequence.to_i64
  when timeout(timeout)
    raise "Timed out waiting for a protocol event for command ##{result.sequence}."
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
  timeout : Time::Span = DEFAULT_TIMEOUT,
  interval : Time::Span = 25.milliseconds,
  &condition : -> Bool
) : Bool
  deadline = Time.instant + timeout
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

  if @restore_client
    cleanup_step("Return to original session") { return_to_origin }
  end

  if @cleanup == :always && @session_name
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
  name = @session_name || return

  if definition = @definition
    failure : Exception? = nil
    begin
      definition.stop
    rescue ex
      failure = ex
      @server.cmd("kill-session", "-t", name)
    end

    begin
      wait_for_custom_host
    rescue ex
      failure ||= ex
    end

    raise failure.not_nil! if failure
  else
    begin
      Session.new(name).stop
    rescue ex
      @server.cmd("kill-session", "-t", name)
      raise ex
    end
  end

  removed = wait_until(HOST_STOP_TIMEOUT) do
    !@server.cmd("has-session", "-t", name).success?
  end
  raise "Tmux session #{name.inspect} was not removed." unless removed
end

private def wait_for_custom_host : Nil
  result = @host_result || return
  message = ""

  select
  when value = result.receive
    message = value
  when timeout(HOST_STOP_TIMEOUT)
    raise "Timed out waiting for the custom command host to stop."
  end

  raise "Custom command host failed: #{message}" unless message.empty?
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
    if @cleanup == :never
      puts "The smoke-test session was left open: #{name}"
      puts "Return to it with: tmux switch-client -t '#{name}'"
    else
      puts "The temporary smoke-test session was cleaned up: #{name}"
    end
  else
    puts "No smoke-test session was created."
  end
  puts "Machine-readable report: #{machine_report_path}"
end
