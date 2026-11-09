require "../crystal_helper"
require "../../src/tmux_repl"

class SuiteFixtureScenario < TmuxREPL::Testing::Scenario
end

class RecordingScenarioSuite < TmuxREPL::Testing::Suite
  getter executed_scenarios : Array(String)

  @failures : Array(String)

  def initialize(
    name : String,
    @failures : Array(String) = [] of String,
    fail_fast : Bool = false
  )
    @executed_scenarios = [] of String
    super(name, fail_fast)
  end

  protected def execute_scenario(
    registration : TmuxREPL::Testing::Suite::Registration
  ) : TmuxREPL::Testing::ScenarioResult
    @executed_scenarios << registration.name

    if @failures.includes?(registration.name)
      TmuxREPL::Testing::ScenarioResult.new(
        registration.name, :failed, 1.0, nil, "fixture failure"
      )
    else
      TmuxREPL::Testing::ScenarioResult.new(
        registration.name, :passed, 1.0, nil, nil
      )
    end
  end

  protected def print_report(
    results : Array(TmuxREPL::Testing::ScenarioResult),
    duration_ms : Float64,
    report_path : String
  ) : Nil
  end
end

def with_suite_state(&block : String -> T) : T forall T
  directory = File.join(
    "/tmp",
    "tmux-repl-suite-spec-#{Process.pid}-#{Time.utc.to_unix_ms}"
  )
  FileUtils.rm_rf(directory)

  with_environment("XDG_STATE_HOME", directory) do
    yield directory
  end
ensure
  FileUtils.rm_rf(directory)
end

describe TmuxREPL::Testing::Suite do
  it "runs scenarios in registration order and continues after failures" do
    suite = RecordingScenarioSuite.new("continue", ["first"])
    suite.add(SuiteFixtureScenario, name: "first")
    suite.add(SuiteFixtureScenario, name: "second")
    suite.add(SuiteFixtureScenario, name: "third")

    with_suite_state do |directory|
      report = suite.run

      suite.executed_scenarios.should eq(["first", "second", "third"])
      report.scenarios.map(&.status).should eq([:failed, :passed, :passed])
      report.success?.should be_false
      report.exit_code.should eq(1)

      machine_report = JSON.parse(File.read(report.report_path))
      machine_report["suite"].as_s.should eq("continue")
      machine_report["status"].as_s.should eq("failed")
      machine_report["scenarios"].as_a.size.should eq(3)
      File.exists?(report.report_path).should be_true
      report.report_path.includes?(directory).should be_true
    end
  end

  it "skips remaining scenarios after the first failure in fail-fast mode" do
    suite = RecordingScenarioSuite.new("fail-fast", ["first"], fail_fast: true)
    suite.add(SuiteFixtureScenario, name: "first")
    suite.add(SuiteFixtureScenario, name: "second")
    suite.add(SuiteFixtureScenario, name: "third")

    with_suite_state do
      report = suite.run

      suite.executed_scenarios.should eq(["first"])
      report.scenarios.map(&.status).should eq([:failed, :skipped, :skipped])
      report.success?.should be_false
      report.exit_code.should eq(1)
    end
  end

  it "rejects duplicate scenario names" do
    suite = RecordingScenarioSuite.new("duplicates")
    suite.add(SuiteFixtureScenario, name: "same")

    expect_raises(ArgumentError, "already registered") do
      suite.add(SuiteFixtureScenario, name: "same")
    end
  end

  it "rejects an empty suite" do
    suite = RecordingScenarioSuite.new("empty")

    expect_raises(Exception, "Cannot run an empty test suite") do
      suite.run
    end
  end
end
