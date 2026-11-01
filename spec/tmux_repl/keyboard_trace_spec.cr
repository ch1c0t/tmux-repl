require "../../src/tmux_repl"

describe TmuxREPL::Keyboard::Trace do
  it "records the pressed character, timestamp, action, and inter-character delay" do
    directory = File.join(Dir.tempdir, "tmux-repl-keyboard-trace-#{Process.pid}")
    path = File.join(directory, "keyboard.trace.log")
    trace = TmuxREPL::Keyboard::Trace.new("trace-spec", "input", path)

    begin
      first = TmuxREPL::Keyboard::KeyPress.new('x', nil)
      trace.record(first, "reply_input", "handled_by_reply")

      sleep 5.milliseconds

      second = TmuxREPL::Keyboard::KeyPress.new(
        '\u0007',
        TmuxREPL::Keyboard::Action::ToggleOutputView
      )
      trace.record(second, "ToggleOutputView", "published")
    ensure
      trace.close
    end

    rows = File.read(path).lines
    rows.size.should eq(2)
    rows[0].should contain("pressed_at=")
    rows[0].should contain("character='x'")
    rows[0].should contain("action=reply_input")
    rows[0].should contain("elapsed_since_previous_ms=first")
    rows[1].should contain("character='\\a'")
    rows[1].should contain("action=ToggleOutputView")
    rows[1].should contain("elapsed_since_previous_ms=")
    rows[1].should contain("result=published")
  ensure
    FileUtils.rm_rf(directory) if directory
  end
end
