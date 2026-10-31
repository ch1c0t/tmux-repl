require "../../src/output"

describe Output::View do
  it "shows an empty view before any input is submitted" do
    view = Output::View.new
    output = IO::Memory.new

    view.render(output)

    output.to_s.should contain("No inputs yet.")
  end

  it "shows the newest input while it is running" do
    view = Output::View.new
    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"echo hello"})))
    output = IO::Memory.new

    view.render(output)

    output.to_s.should contain("INPUT #1")
    output.to_s.should contain("echo hello")
    output.to_s.should contain("(running...)")
  end

  it "accumulates output chunks and displays the completion status" do
    view = Output::View.new
    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"printf hello"})))
    view.update(JSON.parse(%({"type":"output","sequence":1,"chunk":"hel"})))
    view.update(JSON.parse(%({"type":"output","sequence":1,"chunk":"lo"})))
    view.update(JSON.parse(%({"type":"complete","sequence":1,"status":0})))
    output = IO::Memory.new

    view.render(output)

    output.to_s.should contain("hello")
    output.to_s.should contain("[exit status: 0]")
    output.to_s.should_not contain("(running...)")
  end

  it "shows the selected input and ignores selection of an unknown input" do
    view = Output::View.new
    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"first"})))
    view.update(JSON.parse(%({"type":"input","sequence":2,"command":"second"})))
    view.update(JSON.parse(%({"type":"select","sequence":1})))
    view.update(JSON.parse(%({"type":"select","sequence":99})))
    output = IO::Memory.new

    view.render(output)

    output.to_s.should contain("INPUT #1")
    output.to_s.should contain("first")
    output.to_s.should_not contain("INPUT #2")
  end
end
