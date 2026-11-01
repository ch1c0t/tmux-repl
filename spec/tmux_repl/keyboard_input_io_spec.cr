require "../../src/tmux_repl"

describe TmuxREPL::Keyboard::InputIO do
  it "keeps a carriage return separate from a batched text read" do
    source = IO::Memory.new("command\rnext")
    input = TmuxREPL::Keyboard::InputIO.new(source)
    buffer = Bytes.new(1024)

    first_size = input.read(buffer)
    String.new(buffer[0, first_size]).should eq("command")

    second_size = input.read(buffer)
    String.new(buffer[0, second_size]).should eq("\r")

    third_size = input.read(buffer)
    String.new(buffer[0, third_size]).should eq("next")
  end
end
