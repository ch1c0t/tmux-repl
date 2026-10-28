require "pty"

describe PTY do
  it "captures combined terminal output and the process exit code" do
    output, status = PTY.run("printf stdout-token; printf stderr-token >&2; exit 17")

    output.should contain("stdout-token")
    output.should contain("stderr-token")
    status.should eq(17)
  end

  it "streams terminal output before the command completes" do
    log = ""
    result_channel = Channel(Tuple(String, Int32)).new

    begin
      log = File.join(ENV["TMPDIR"]? || "/tmp", "tmux-repl-pty-#{Process.pid}.log")
      File.write(log, "")

      spawn do
        result_channel.send(PTY.run("printf PTY_FIRST; sleep 1; printf PTY_SECOND") do |chunk|
          File.open(log, "a") { |file| file.print(chunk) }
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
      output, status = result_channel.receive
      output.should contain("PTY_SECOND")
      status.should eq(0)
    ensure
      File.delete(log) if !log.empty? && File.exists?(log)
    end
  end
end
