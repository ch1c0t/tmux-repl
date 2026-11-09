require "../crystal_helper"
require "../../src/tmux_repl"

def test_configuration(
  name : String = "tmux.repl.custom_repl",
  focus : Bool = true,
  cleanup : Symbol = :always,
  restore_client : Bool = true,
  step_delay : Time::Span = 0.seconds,
  timeout : Time::Span = 8.seconds,
  start_timeout : Time::Span = 8.seconds,
  host_stop_timeout : Time::Span = 5.seconds
)
  TmuxREPL::Testing::Configuration.from_env(
    name,
    focus,
    cleanup,
    restore_client,
    step_delay,
    timeout,
    start_timeout,
    host_stop_timeout
  )
end

describe TmuxREPL::Testing::Configuration do
  it "prefers scenario-specific values over shared values" do
    with_environment("TMUX_REPL_TEST_FOCUS", "1") do
      with_environment("TMUX_REPL_TEST_CUSTOM_REPL_FOCUS", "0") do
        test_configuration.focus.should be_false
      end
    end
  end

  it "falls back to shared values when no scenario-specific value exists" do
    with_environment("TMUX_REPL_TEST_DELAY", "0.25") do
      test_configuration.step_delay.should eq(0.25.seconds)
    end
  end

  it "parses cleanup policies and timeouts" do
    with_environment("TMUX_REPL_TEST_CUSTOM_REPL_CLEANUP", "on_failure") do
      with_environment("TMUX_REPL_TEST_CUSTOM_REPL_TIMEOUT", "2.5") do
        config = test_configuration
        config.cleanup.should eq(:on_failure)
        config.timeout.should eq(2.5.seconds)
      end
    end
  end

  it "rejects invalid boolean values" do
    with_environment("TMUX_REPL_TEST_FOCUS", "sometimes") do
      expect_raises(ArgumentError, "Invalid boolean") do
        test_configuration
      end
    end
  end

  it "rejects invalid durations" do
    with_environment("TMUX_REPL_TEST_TIMEOUT", "-1") do
      expect_raises(ArgumentError, "non-negative") do
        test_configuration
      end
    end
  end

  it "requires restoring the client before cleaning up a focused session" do
    expect_raises(ArgumentError, "restore_client must be enabled") do
      test_configuration(focus: true, cleanup: :always, restore_client: false)
    end
  end
end


# Lightweight scenarios exercise the macro-generated step chain without
# creating a Tmux session or starting the interactive testing lifecycle.
abstract class ScenarioStepChainFixture < TmuxREPL::Testing::Scenario
  @executed_steps = [] of String

  getter executed_steps : Array(String)

  # Bypass Testing#initialize: these unit tests need no Tmux resources.
  def prepare_for_test : self
    @executed_steps = [] of String
    self
  end

  private def record_step(name : String, &block : -> T) : Nil forall T
    @executed_steps << name
    yield
  end
end

class ParentScenarioStepFixture < ScenarioStepChainFixture
  step "parent step" do
    executed_steps << "parent body"
  end
end

class ChildScenarioStepFixture < ParentScenarioStepFixture
  step "child step" do
    executed_steps << "child body"
  end
end

describe TmuxREPL::Testing::Scenario do
  it "executes inherited and local steps in declaration order" do
    scenario = ChildScenarioStepFixture.allocate.prepare_for_test

    scenario.execute_steps

    scenario.executed_steps.should eq([
      "parent step",
      "parent body",
      "child step",
      "child body",
    ])
  end

  it "keeps step execution state isolated between instances" do
    first = ChildScenarioStepFixture.allocate.prepare_for_test
    second = ChildScenarioStepFixture.allocate.prepare_for_test

    first.execute_steps

    first.executed_steps.size.should eq(4)
    second.executed_steps.should be_empty
  end
end
