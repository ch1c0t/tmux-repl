require "spec"
require "time"
require "../src/tmux"

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
end

describe Tmux::Server do
  it "creates a session, splits a pane, sends keys, and captures output" do
    socket_name = "crystal_tmux_api_spec_#{Process.pid}"
    server = Tmux::Server.new(socket_name)

    begin
      session = server.new_session("api-spec", detached: true, window_name: "main")
      session.session_name.should eq("api-spec")

      window = session.active_window
      window.window_name.should eq("main")
      pane = window.active_pane
      split = pane.split(:right, detached: true)
      split.window.window_id.should eq(window.window_id)

      pane.send_keys("printf 'TMUX_API_READY'")
      deadline = Time.instant + 3.seconds
      found = false
      while Time.instant < deadline
        found = pane.capture_pane.join("\n").includes?("TMUX_API_READY")
        break if found
        sleep 50.milliseconds
      end
      found.should be_true
    ensure
      begin
        server.kill_server
      rescue Tmux::Error
      end
    end
  end
end
