require "../../src/output"

describe Output::View do
  it "redraws rows in place without clearing the entire pane" do
    view = Output::View.new
    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"echo hello"})))
    output = IO::Memory.new

    view.render(output, height: 8)

    frame = output.to_s
    frame.should_not contain("\e[2J")
    frame.should contain("\e[1;1H")
    frame.should contain("\e[8;1H")
    frame.should contain("\e[0K")
    frame.scan(/\e\[(\d+);1H/).map(&.[1]).should eq((1..8).map(&.to_s))
  end

  it "shows an empty view before any input is submitted" do
    view = Output::View.new
    output = IO::Memory.new

    view.render(output)

    output.to_s.should contain("No inputs yet.")
  end

  it "reports zero output lines without counting the running placeholder" do
    view = Output::View.new
    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"wait for output"})))

    streaming = IO::Memory.new
    view.render(streaming, height: 8)
    streaming.to_s.should contain("(running...)")
    streaming.to_s.should contain("[0 output lines so far]")

    view.update(JSON.parse({"type" => "complete", "sequence" => 1, "status" => 0, "clean_output" => ""}.to_json))
    completed = IO::Memory.new
    view.render(completed, height: 8)
    completed.to_s.should contain("[0 output lines]")
    completed.to_s.should_not contain("[0 output lines so far]")
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
    streaming.to_s.should contain("[Output lines 1–4 of 4 so far]")

    view.update(JSON.parse({"type" => "complete", "sequence" => 1, "status" => 0, "clean_output" => "tick\n"}.to_json))

    stripped = IO::Memory.new
    view.render(stripped)
    stripped.to_s.should contain("tick")
    stripped.to_s.should_not contain("START_MARK_123")
    stripped.to_s.should_not contain("END_MARK_123")
    stripped.to_s.should contain("[exit status: 0]")
    stripped.to_s.should contain("[Output lines 1–1 of 1]")
  end

  it "handles a view-toggle event published by the input pane" do
    view = Output::View.new
    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"run task"})))
    view.update(JSON.parse({"type" => "output", "sequence" => 1, "chunk" => "START_MARK_1\nclean data\nEND_MARK_1__0__"}.to_json))
    view.update(JSON.parse({"type" => "complete", "sequence" => 1, "status" => 0, "clean_output" => "clean data\n"}.to_json))

    stripped = IO::Memory.new
    view.render(stripped)
    stripped.to_s.should contain("clean data")
    stripped.to_s.should_not contain("START_MARK_1")

    view.update(JSON.parse(%({"type":"toggle_view","sequence":0})))
    raw = IO::Memory.new
    view.render(raw)
    raw.to_s.should contain("START_MARK_1")
    raw.to_s.should contain("END_MARK_1")
    raw.to_s.should contain("[Output lines 1–3 of 3]")

    view.update(JSON.parse(%({"type":"toggle_view","sequence":0})))
    stripped_again = IO::Memory.new
    view.render(stripped_again)
    stripped_again.to_s.should contain("clean data")
    stripped_again.to_s.should_not contain("START_MARK_1")
    stripped_again.to_s.should contain("[Output lines 1–1 of 1]")
  end

  it "handles scroll events published by the input pane" do
    view = Output::View.new
    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"generate output"})))
    output_lines = (1..10).map { |number| "OUTPUT_LINE_#{number.to_s.rjust(2, '0')}" }.join("\n")
    view.update(JSON.parse({"type" => "complete", "sequence" => 1, "status" => 0, "clean_output" => output_lines}.to_json))

    initial = IO::Memory.new
    view.render(initial, height: 8)
    initial.to_s.should contain("OUTPUT_LINE_10")
    initial.to_s.should_not contain("OUTPUT_LINE_01")
    initial.to_s.should contain("[Output lines 9–10 of 10]")

    view.update(JSON.parse(%({"type":"scroll","sequence":0,"action":"ScrollPageUp"})))
    earlier = IO::Memory.new
    view.render(earlier, height: 8)
    earlier.to_s.should contain("OUTPUT_LINE_08")
    earlier.to_s.should_not contain("OUTPUT_LINE_10")
    earlier.to_s.should contain("[Output lines 8–9 of 10]")

    view.update(JSON.parse(%({"type":"scroll","sequence":0,"action":"ScrollDown"})))
    later = IO::Memory.new
    view.render(later, height: 8)
    later.to_s.should contain("OUTPUT_LINE_10")
    later.to_s.should contain("[Output lines 9–10 of 10]")
  end

  it "reports when the pane is too short to show any output lines" do
    view = Output::View.new
    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"generate output"})))
    view.update(JSON.parse({"type" => "output", "sequence" => 1, "chunk" => "one\ntwo\nthree\nfour"}.to_json))

    output = IO::Memory.new
    view.render(output, height: 1)

    output.to_s.should contain("[0 of 4 output lines visible]")
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

  it "scrolls output by line and by page while keeping the header and status visible" do
    view = Output::View.new
    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"generate output"})))
    output_lines = (1..10).map { |number| "OUTPUT_LINE_#{number.to_s.rjust(2, '0')}" }.join("\n")
    view.update(JSON.parse({"type" => "complete", "sequence" => 1, "status" => 0, "clean_output" => output_lines}.to_json))

    initial = IO::Memory.new
    view.render(initial, height: 8)
    initial.to_s.should contain("OUTPUT_LINE_10")
    initial.to_s.should_not contain("OUTPUT_LINE_01")
    initial.to_s.should contain("[Output lines 9–10 of 10]")

    view.scroll(TmuxREPL::Keyboard::Action::ScrollPageUp).should be_true
    earlier = IO::Memory.new
    view.render(earlier, height: 8)
    earlier.to_s.should contain("OUTPUT_LINE_08")
    earlier.to_s.should_not contain("OUTPUT_LINE_10")
    earlier.to_s.should contain("[Output lines 8–9 of 10]")
    earlier.to_s.should contain("INPUT #1")
    earlier.to_s.should contain("[exit status: 0]")

    view.scroll(TmuxREPL::Keyboard::Action::ScrollUp).should be_true
    higher = IO::Memory.new
    view.render(higher, height: 8)
    higher.to_s.should contain("OUTPUT_LINE_07")
    higher.to_s.should contain("[Output lines 7–8 of 10]")

    2.times { view.scroll(TmuxREPL::Keyboard::Action::ScrollPageDown) }
    latest = IO::Memory.new
    view.render(latest, height: 8)
    latest.to_s.should contain("OUTPUT_LINE_10")
    latest.to_s.should contain("[Output lines 9–10 of 10]")
  end
end
