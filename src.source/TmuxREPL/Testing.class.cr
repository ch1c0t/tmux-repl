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

include Assertions
include Cleanup
include Commands
include Events
include Helpers
include Lifecycle
include Reporting
include Start
include Steps

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

def self.run(
  scenario_class : T.class,
  name : String,
  cleanup : Symbol = :never,
  focus : Bool = true,
  restore_client : Bool = true,
  step_delay : Time::Span = 0.seconds,
  timeout : Time::Span = DEFAULT_TIMEOUT,
  start_timeout : Time::Span = START_TIMEOUT,
  host_stop_timeout : Time::Span = HOST_STOP_TIMEOUT
) : Nil forall T
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
  scenario = scenario_class.new(name, configuration)
  scenario.run { scenario.execute_steps }
end

def self.run_result(
  scenario_class : T.class,
  name : String,
  cleanup : Symbol = :never,
  focus : Bool = true,
  restore_client : Bool = true,
  step_delay : Time::Span = 0.seconds,
  timeout : Time::Span = DEFAULT_TIMEOUT,
  start_timeout : Time::Span = START_TIMEOUT,
  host_stop_timeout : Time::Span = HOST_STOP_TIMEOUT
) : ScenarioResult forall T
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
  scenario = scenario_class.new(name, configuration)
  scenario.run_result { |_runner| scenario.execute_steps }
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
