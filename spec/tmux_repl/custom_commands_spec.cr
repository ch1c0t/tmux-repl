require "../../src/tmux_repl"

describe TmuxREPL::CommandLine do
  it "splits unquoted arguments" do
    TmuxREPL::CommandLine.parse("key press Escape").should eq(["key", "press", "Escape"])
  end

  it "preserves spaces in single- and double-quoted arguments" do
    TmuxREPL::CommandLine.parse(%(echo "hello world" 'from a fixture')).should eq(
      ["echo", "hello world", "from a fixture"]
    )
  end

  it "supports escaped whitespace" do
    TmuxREPL::CommandLine.parse("echo hello\\ world").should eq(["echo", "hello world"])
  end

  it "preserves explicitly empty quoted arguments" do
    TmuxREPL::CommandLine.parse(%(echo "")).should eq(["echo", ""])
  end

  it "rejects unterminated quotes" do
    expect_raises(ArgumentError, "Unterminated quote") do
      TmuxREPL::CommandLine.parse(%(echo "unfinished))
    end
  end

  it "rejects a trailing escape" do
    expect_raises(ArgumentError, "Trailing escape") do
      TmuxREPL::CommandLine.parse("echo unfinished\\")
    end
  end
end

describe TmuxREPL::Definition do
  it "registers uniquely named custom commands" do
    definition = TmuxREPL.define("custom") do |repl|
      repl.on_command("ocr") { |_context, _arguments| }
      repl.on_command("key") { |_context, _arguments| }
    end

    definition.command_names.should eq(["key", "ocr"])
    definition.custom_commands?.should be_true
    definition.session.custom_command_mode.should be_true
  end

  it "rejects duplicate custom command names" do
    expect_raises(ArgumentError, "already registered") do
      TmuxREPL.define("custom") do |repl|
        repl.on_command("ocr") { |_context, _arguments| }
        repl.on_command("ocr") { |_context, _arguments| }
      end
    end
  end

  it "rejects invalid custom command names" do
    expect_raises(ArgumentError, "Invalid custom command") do
      TmuxREPL.define("custom") do |repl|
        repl.on_command("key press") { |_context, _arguments| }
      end
    end
  end

  it "does not combine custom handlers with a native REPL command" do
    expect_raises(ArgumentError, "Cannot register custom commands") do
      TmuxREPL.define("custom") do |repl|
        repl.command("python3", "-i")
        repl.on_command("ocr") { |_context, _arguments| }
      end
    end

    expect_raises(ArgumentError, "Cannot configure a native command") do
      TmuxREPL.define("custom") do |repl|
        repl.on_command("ocr") { |_context, _arguments| }
        repl.command("python3", "-i")
      end
    end
  end
end
