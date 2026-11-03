require "./helper"
require "./lavinmq_process/Diagnostics"

describe LavinMQProcess::DiagnosticFormatting do
  it "keeps the section heading attached to its table" do
    report = LavinMQProcess::DiagnosticFormatting.table(
      "PROCESS STATE",
      ["Process", "PID"],
      [["Input", "13335"]],
      [12, 12]
    )

    lines = report.lines
    lines[0].should contain("PROCESS STATE")
    lines[1].should start_with("| Process")
    lines[2].should start_with("+")
    lines[0].size.should eq(lines[1].size)
  end

  it "preserves spaces inside keyboard character fields" do
    row = LavinMQProcess::DiagnosticFormatting.keyboard_event_row(
      "pressed_at=2026-11-03T22:39:15.128560Z pane=output pid=13440 character=' ' " \
      "action=ToggleOutputView elapsed_since_previous_ms=first result=published"
    )

    row.should eq([
      "22:39:15.128560",
      "output",
      "13440",
      "' '",
      "ToggleOutputView",
      "first",
      "published",
    ])
  end

  it "wraps long pane lines without dropping their contents" do
    contents = "abcdefghijklmnopqrstuvwxyz"
    report = LavinMQProcess::DiagnosticFormatting.frame("OUTPUT PANE", contents, 10)

    report.should contain("abcdefghij")
    report.should contain("klmnopqrst")
    report.should contain("uvwxyz")
  end
end
