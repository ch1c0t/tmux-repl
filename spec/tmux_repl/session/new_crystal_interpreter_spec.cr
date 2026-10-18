require "./helper"

describe "TmuxREPL::Session.crystal_interpreter" do
  it "provides a Crystal interpreter preset" do
    session = TmuxREPL::Session.crystal_interpreter
    session.name.should eq("crystal")
    session.command.should eq(["ic"])
  end

  it "allows overriding the Crystal interpreter executable" do
    session = TmuxREPL::Session.crystal_interpreter("crystal-dev", "/opt/crystal/bin/icr")
    session.name.should eq("crystal-dev")
    session.command.should eq(["/opt/crystal/bin/icr"])
  end
end
