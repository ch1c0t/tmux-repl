require "../../src/tmux_repl"

describe TmuxREPL::Definition do
  it "defines a named native REPL with command, environment, and working directory" do
    definition = TmuxREPL.define("python") do |repl|
      repl.command "python3", "-i"
      repl.env "PYTHONSTARTUP", "/tmp/pythonrc"
      repl.cwd "/tmp"
    end

    definition.name.should eq("python")

    session = definition.session
    session.name.should eq("python")
    session.command.should eq(["python3", "-i"])
    session.environment.should eq({"PYTHONSTARTUP" => "/tmp/pythonrc"})
    session.start_directory.should eq("/tmp")
  end

  it "uses the standard shell worker when no native command is configured" do
    session = TmuxREPL.define("shell") { |_repl| }.session

    session.command.should be_nil
  end

  it "rejects an empty native REPL command" do
    expect_raises(ArgumentError) do
      TmuxREPL.define("empty") { |repl| repl.command([] of String) }
    end
  end
end
