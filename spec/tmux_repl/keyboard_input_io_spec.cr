require "../../src/tmux_repl"

describe TmuxREPL::Keyboard::InputIO do
  it "keeps a carriage return separate from a batched text read" do
    source = IO::Memory.new("command\rnext\n")
    input = TmuxREPL::Keyboard::InputIO.new(source)
    buffer = Bytes.new(1024)

    first_size = input.read(buffer)
    String.new(buffer[0, first_size]).should eq("command")

    second_size = input.read(buffer)
    String.new(buffer[0, second_size]).should eq("\r")

    third_size = input.read(buffer)
    String.new(buffer[0, third_size]).should eq("next")

    fourth_size = input.read(buffer)
    String.new(buffer[0, fourth_size]).should eq("\n")
  end

  it "translates classic Alt+K/J sequences and retains their binding labels" do
    previous = TmuxREPL::Keyboard::InputIO.new(IO::Memory.new("\ek"))
    next_input = TmuxREPL::Keyboard::InputIO.new(IO::Memory.new("\ej"))
    buffer = Bytes.new(1024)

    size = previous.read(buffer)
    String.new(buffer[0, size]).should eq("\e[1;5A")
    previous.take_navigation_binding(TmuxREPL::Keyboard::Action::SelectPrevious).not_nil!.label.should eq("Alt+K")

    size = next_input.read(buffer)
    String.new(buffer[0, size]).should eq("\e[1;5B")
    next_input.take_navigation_binding(TmuxREPL::Keyboard::Action::SelectNext).not_nil!.label.should eq("Alt+J")
  end

  it "translates Kitty Alt+J/K sequences" do
    previous = TmuxREPL::Keyboard::InputIO.new(IO::Memory.new("\e[107;3u"))
    next_input = TmuxREPL::Keyboard::InputIO.new(IO::Memory.new("\e[106;3u"))
    buffer = Bytes.new(1024)

    size = previous.read(buffer)
    String.new(buffer[0, size]).should eq("\e[1;5A")
    previous.take_navigation_binding(TmuxREPL::Keyboard::Action::SelectPrevious).not_nil!.label.should eq("Alt+K")

    size = next_input.read(buffer)
    String.new(buffer[0, size]).should eq("\e[1;5B")
    next_input.take_navigation_binding(TmuxREPL::Keyboard::Action::SelectNext).not_nil!.label.should eq("Alt+J")
  end


  it "separates ordinary text from a following navigation sequence" do
    input = TmuxREPL::Keyboard::InputIO.new(IO::Memory.new("shell\ek"))
    buffer = Bytes.new(1024)

    size = input.read(buffer)
    String.new(buffer[0, size]).should eq("shell")

    size = input.read(buffer)
    String.new(buffer[0, size]).should eq("\e[1;5A")
    input.take_navigation_binding(TmuxREPL::Keyboard::Action::SelectPrevious).not_nil!.label.should eq("Alt+K")
  end

  it "retains native Ctrl+Up/Down bindings" do
    input = TmuxREPL::Keyboard::InputIO.new(IO::Memory.new("\e[1;5A\e[1;5B"))
    buffer = Bytes.new(1024)

    size = input.read(buffer)
    String.new(buffer[0, size]).should eq("\e[1;5A")
    input.take_navigation_binding(TmuxREPL::Keyboard::Action::SelectPrevious).not_nil!.label.should eq("Ctrl+Up")

    size = input.read(buffer)
    String.new(buffer[0, size]).should eq("\e[1;5B")
    input.take_navigation_binding(TmuxREPL::Keyboard::Action::SelectNext).not_nil!.label.should eq("Ctrl+Down")
  end
end
