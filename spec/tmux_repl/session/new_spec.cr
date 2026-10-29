require "./helper"

describe TmuxREPL::Session do
  it "accepts an arbitrary interactive REPL command" do
    session = TmuxREPL::Session.new("python", command: ["python3", "-i"])

    session.name.should eq("python")
    session.command.should eq(["python3", "-i"])
  end

  it "rejects an empty interactive REPL command" do
    expect_raises(ArgumentError) do
      TmuxREPL::Session.new("empty", command: [] of String)
    end
  end
end
