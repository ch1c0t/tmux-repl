require "./helper"

describe TmuxREPL::Session do
  it "accepts an arbitrary interactive REPL command" do
    session = TmuxREPL::Session.new("python", command: ["python3", "-i"])

    session.name.should eq("python")
    session.command.should eq(["python3", "-i"])
  end

  it "accepts companion executable overrides as constructor options" do
    session = TmuxREPL::Session.new(
      "custom",
      input_executable: "/custom/bin/tmux.repl.input",
      output_executable: "/custom/bin/tmux.repl.output",
      worker_executable: "/custom/bin/tmux.repl.worker"
    )

    session.input_executable.should eq("/custom/bin/tmux.repl.input")
    session.output_executable.should eq("/custom/bin/tmux.repl.output")
    session.worker_executable.should eq("/custom/bin/tmux.repl.worker")
  end

  it "rejects an empty interactive REPL command" do
    expect_raises(ArgumentError) do
      TmuxREPL::Session.new("empty", command: [] of String)
    end
  end
end
