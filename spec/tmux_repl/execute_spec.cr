require "./session/helper"

describe TmuxREPL do
  it "captures combined terminal output and the process exit code" do
    result = TmuxREPL.execute("printf stdout-token; printf stderr-token >&2; exit 17")

    result.output.should contain("stdout-token")
    result.output.should contain("stderr-token")
    result.status.should eq(17)
  end

  it "streams terminal output before the command completes" do
    log = File.join(ENV["TMPDIR"]? || "/tmp", "tmux-repl-pty-#{Process.pid}.log")
    File.write(log, "")
    result_channel = Channel(TmuxREPL::Result).new

    spawn do
      result_channel.send(TmuxREPL.execute("printf PTY_FIRST; sleep 1; printf PTY_SECOND") do |chunk|
        TmuxREPL.append_output(log, chunk)
      end)
    end

    found_first = false
    deadline = Time.instant + 700.milliseconds
    while Time.instant < deadline
      if File.read(log).includes?("PTY_FIRST")
        found_first = true
        File.read(log).should_not contain("PTY_SECOND")
        break
      end
      sleep 10.milliseconds
    end

    found_first.should be_true
    result = result_channel.receive
    result.output.should contain("PTY_SECOND")
    result.status.should eq(0)
  ensure
    File.delete(log) if File.exists?(log)
  end
end
