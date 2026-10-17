require "spec"
require "time"
require "../../src/tmux"

describe Tmux::Client do
  it "captures output and preserves a command's exit status" do
    result = Tmux::Client.new("/bin/sh").run(
      "-c",
      "printf 'API_STDOUT'; printf 'API_STDERR' >&2; exit 7"
    )

    result.stdout.should eq("API_STDOUT")
    result.stderr.should eq("API_STDERR")
    result.exit_code.should eq(7)
    result.success?.should be_false
  end

  it "raises a typed error when run! sees a nonzero exit status" do
    expect_raises(Tmux::CommandError) do
      Tmux::Client.new("/bin/sh").run!("-c", "exit 3")
    end
  end

  it "can unset TMUX for an interactive child process" do
    previous = ENV["TMUX"]?
    ENV["TMUX"] = "nested"

    begin
      Tmux::Client.new("/bin/sh").interactive!("-c", "test -z \"$TMUX\"", unset_tmux: true)
    ensure
      ENV["TMUX"] = previous
    end
  end

  it "switches the current tmux client to the selected session" do
    base = File.join(ENV["TMPDIR"]? || "/tmp", "tmux-api-spec-#{Process.pid}")
    binary = "#{base}.sh"
    output = "#{base}.args"
    File.write(binary, "#!/bin/sh\\nprintf '%s\\n' \"$@\" > #{output}\\n")
    File.chmod(binary, 0o755)

    begin
      server = Tmux::Server.new(nil, nil, binary)
      Tmux::Session.new(server, "$target").switch_client
      File.read(output).should eq("switch-client\\n-t\\n$target\\n")
    ensure
      File.delete(binary) if File.exists?(binary)
      File.delete(output) if File.exists?(output)
    end
  end
end
