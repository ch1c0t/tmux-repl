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

end
