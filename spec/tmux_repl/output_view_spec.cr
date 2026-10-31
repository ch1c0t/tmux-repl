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

  it "streams raw output while running, then switches to clean output" do
    view = Output::View.new
    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"run task"})))
    raw_transcript = "START_MARK_123\nrun task\ntick\nEND_MARK_123__0__"
    view.update(JSON.parse({"type" => "output", "sequence" => 1, "chunk" => raw_transcript}.to_json))

    streaming = IO::Memory.new
    view.render(streaming)
    streaming.to_s.should contain("START_MARK_123")
    streaming.to_s.should contain("tick")

    view.update(JSON.parse({"type" => "complete", "sequence" => 1, "status" => 0, "clean_output" => "tick\n"}.to_json))

    stripped = IO::Memory.new
    view.render(stripped)
    stripped.to_s.should contain("tick")
    stripped.to_s.should_not contain("START_MARK_123")
    stripped.to_s.should_not contain("END_MARK_123")
    stripped.to_s.should contain("[exit status: 0]")
  end

  it "toggles between stripped and raw views for completed commands" do
    view = Output::View.new
    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"run task"})))
    view.update(JSON.parse({"type" => "output", "sequence" => 1, "chunk" => "START_MARK_1\nclean data\nEND_MARK_1__0__"}.to_json))
    view.update(JSON.parse({"type" => "complete", "sequence" => 1, "status" => 0, "clean_output" => "clean data\n"}.to_json))

    stripped = IO::Memory.new
    view.render(stripped)
    stripped.to_s.should contain("clean data")
    stripped.to_s.should_not contain("START_MARK_1")

    view.toggle_view.should be_true
    raw = IO::Memory.new
    view.render(raw)
    raw.to_s.should contain("START_MARK_1")
    raw.to_s.should contain("END_MARK_1")

    view.toggle_view.should be_false
    stripped_again = IO::Memory.new
    view.render(stripped_again)
    stripped_again.to_s.should contain("clean data")
    stripped_again.to_s.should_not contain("START_MARK_1")
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
