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
