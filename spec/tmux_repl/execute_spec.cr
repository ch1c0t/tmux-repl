require "pty"
require "../crystal_helper"

describe PTY do
  it "captures terminal output and the process exit code" do
    output, status = PTY.run("printf stdout-token; printf stderr-token >&2; exit 17")

    output.should contain("stdout-token")
    output.should contain("stderr-token")
    status.should eq(17)
  end

  it "streams terminal output before the command completes" do
    log_path = File.join(ENV["TMPDIR"]? || "/tmp", "tmux-repl-pty-#{Process.pid}.log")
    result_channel = Channel(Tuple(String, Int32)).new
    File.write(log_path, "")

    begin
      spawn do
        result_channel.send(
          PTY.run("printf '\\nLIVE_FIRST\\n'; sleep 1; printf '\\nLIVE_%s\\n' SECOND") do |chunk|
            File.open(log_path, "a") { |file| file.print(chunk) }
          end
        )
      end

      first_output_seen = false
      wait_until(700.milliseconds, 10.milliseconds) do
        content = File.read(log_path)
        if content.includes?("LIVE_FIRST")
          first_output_seen = true
          content.should_not contain("LIVE_SECOND")
        end
        first_output_seen
      end.should be_true

      output, status = result_channel.receive
      output.should contain("LIVE_FIRST")
      output.should contain("LIVE_SECOND")
      status.should eq(0)
    ensure
      File.delete(log_path) if File.exists?(log_path)
    end
  end
end
