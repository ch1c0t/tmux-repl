struct Registration
  getter name : String

  @runner : Proc(ScenarioResult)

  def initialize(@name : String, @runner : Proc(ScenarioResult))
  end

  def run : ScenarioResult
    @runner.call
  end
end

struct Report
  getter name : String
  getter scenarios : Array(ScenarioResult)
  getter duration_ms : Float64
  getter report_path : String

  def initialize(
    @name : String,
    @scenarios : Array(ScenarioResult),
    @duration_ms : Float64,
    @report_path : String
  )
  end

  def success? : Bool
    @scenarios.all?(&.passed?)
  end

  def exit_code : Int32
    success? ? 0 : 1
  end
end

@registrations = [] of Registration
@run_count = 0

def initialize(@name : String, @fail_fast : Bool = false)
  raise ArgumentError.new("Suite name cannot be empty.") if @name.strip.empty?
end

# Register a scenario class. Each registration gets its own Testing
# configuration and a fresh scenario instance when the suite is run.
def add(
  scenario_class : T.class,
  name : String,
  cleanup : Symbol = :never,
  focus : Bool = true,
  restore_client : Bool = true,
  step_delay : Time::Span = 0.seconds,
  timeout : Time::Span = DEFAULT_TIMEOUT,
  start_timeout : Time::Span = START_TIMEOUT,
  host_stop_timeout : Time::Span = HOST_STOP_TIMEOUT
) : self forall T
  raise ArgumentError.new("Scenario name cannot be empty.") if name.strip.empty?
  if @registrations.any? { |registration| registration.name == name }
    raise ArgumentError.new("Scenario #{name.inspect} is already registered in #{@name.inspect}.")
  end

  runner = -> {
    Testing.run_result(
      scenario_class,
      name,
      cleanup,
      focus,
      restore_client,
      step_delay,
      timeout,
      start_timeout,
      host_stop_timeout
    )
  }
  @registrations << Registration.new(name, runner)
  self
end

# Run registered scenarios sequentially. Failures are collected and do not
# stop later scenarios unless fail_fast was enabled when the suite was built.
def run : Report
  raise "Cannot run an empty test suite." if @registrations.empty?

  started_at = Time.instant
  started_at_utc = Time.utc
  results = [] of ScenarioResult
  failed = false

  @registrations.each do |registration|
    if @fail_fast && failed
      results << ScenarioResult.new(
        registration.name,
        :skipped,
        0.0,
        nil,
        "Skipped because an earlier scenario failed."
      )
      next
    end

    scenario_started_at = Time.instant
    begin
      result = execute_scenario(registration)
      results << result
      failed ||= result.failed?
    rescue ex
      results << ScenarioResult.new(
        registration.name,
        :failed,
        (Time.instant - scenario_started_at).total_milliseconds,
        nil,
        "#{ex.class}: #{ex.message}"
      )
      failed = true
    end
  end

  finished_at_utc = Time.utc
  duration_ms = (Time.instant - started_at).total_milliseconds
  @run_count += 1
  report_path = write_machine_report(results, started_at_utc, finished_at_utc, duration_ms)
  print_report(results, duration_ms, report_path)

  Report.new(@name, results, duration_ms, report_path)
end

protected def execute_scenario(registration : Registration) : ScenarioResult
  registration.run
end

protected def print_report(
  results : Array(ScenarioResult),
  duration_ms : Float64,
  report_path : String
) : Nil
  puts
  puts "#{@name} test suite"
  puts "=" * 72

  results.each do |result|
    marker = case result.status
             when :passed then "\e[32mPASS\e[0m"
             when :failed then "\e[31mFAIL\e[0m"
             else "\e[33mSKIP\e[0m"
             end
    details = result.details
    summary = details ? "#{result.duration_ms.round(0)} ms; #{details}" : "#{result.duration_ms.round(0)} ms"
    puts "#{marker}  #{result.name} (#{summary})"
    puts "       Scenario report: #{result.report_path}" if result.report_path
  end

  passed = results.count(&.passed?)
  failed = results.count(&.failed?)
  skipped = results.count(&.skipped?)
  puts
  puts "Scenarios: #{passed} passed, #{failed} failed, #{skipped} skipped"
  puts "Duration: #{duration_ms.round(0)} ms"
  puts "Suite report: #{report_path}"
end

private def write_machine_report(
  results : Array(ScenarioResult),
  started_at : Time,
  finished_at : Time,
  duration_ms : Float64
) : String
  directory = State.smoke_tests_path
  FileUtils.mkdir_p(directory)

  path = File.join(
    directory,
    "suite-#{started_at.to_unix_ms}-#{Process.pid}-#{@run_count}.json"
  )
  temporary_path = "#{path}.tmp"
  passed = results.all?(&.passed?)

  contents = JSON.build(indent: "  ") do |json|
    json.object do
      json.field "schema_version", 1
      json.field "suite", @name
      json.field "status", passed ? "passed" : "failed"
      json.field "exit_code", passed ? 0 : 1
      json.field "started_at_unix_ms", started_at.to_unix_ms
      json.field "finished_at_unix_ms", finished_at.to_unix_ms
      json.field "duration_ms", duration_ms
      json.field "fail_fast", @fail_fast
      json.field "scenarios" do
        json.array do
          results.each do |result|
            json.object do
              json.field "name", result.name
              json.field "status", result.status.to_s
              json.field "duration_ms", result.duration_ms
              json.field "report_path", result.report_path
              json.field "details", result.details
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
