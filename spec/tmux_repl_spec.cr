require "spec"
require "file_utils"
require "time"
require "../src/tmux_repl"

describe TmuxREPL::Session do
  it "accepts an arbitrary interactive REPL command" do
    session = TmuxREPL::Session.new("python", command: ["python3", "-i"])
    session.name.should eq("python")
    session.command.should eq(["python3", "-i"])
  end

  it "provides a Crystal interpreter preset" do
    session = TmuxREPL::Session.crystal_interpreter
    session.name.should eq("crystal")
    session.command.should eq(["icr"])
  end

  it "allows overriding the Crystal interpreter executable" do
    session = TmuxREPL::Session.crystal_interpreter("crystal-dev", "/opt/crystal/bin/icr")
    session.name.should eq("crystal-dev")
    session.command.should eq(["/opt/crystal/bin/icr"])
  end

  it "rejects an empty interactive REPL command" do
    expect_raises(ArgumentError) do
      TmuxREPL::Session.new("empty", command: [] of String)
    end
  end
  it "captures output from an interactive REPL command" do
    name = "repl_spec_#{Process.pid}"
    state_home = File.join(ENV["TMPDIR"]? || "/tmp", "tmux-repl-e2e-#{Process.pid}")
    log = File.join(state_home, "tmux-repl", name, "output.log")
    previous_state_home = ENV["XDG_STATE_HOME"]?
    ENV["XDG_STATE_HOME"] = state_home
    session = TmuxREPL::Session.new(name, command: [
      "sh", "-c", "printf 'TMUX_REPL_LIBRARY_E2E'; sleep 1"
    ])
    found = false

    begin
      session.start(focus: false)
      deadline = Time.instant + 5.seconds
      while Time.instant < deadline
        if File.exists?(log) && File.read(log).includes?("TMUX_REPL_LIBRARY_E2E")
          found = true
          break
        end
        sleep 50.milliseconds
      end
      found.should be_true
    ensure
      session.stop
      ENV["XDG_STATE_HOME"] = previous_state_home
      FileUtils.rm_rf(state_home)
    end
  end
end
