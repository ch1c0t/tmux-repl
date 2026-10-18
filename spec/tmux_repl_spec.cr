require "spec"
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
end
