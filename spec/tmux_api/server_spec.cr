require "spec"
require "time"
require "../../src/tmux"

describe Tmux::Server do
  it "creates a session, splits to the right, sends keys, and captures output" do
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

      left = pane.display_message("\#{pane_left}").to_i
      right = split.display_message("\#{pane_left}").to_i
      right.should be > left

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

  it "starts session and split-pane commands with explicit command arguments" do
    socket_name = "crystal_tmux_direct_api_spec_#{Process.pid}"
    server = Tmux::Server.new(socket_name)

    begin
      session = server.new_session(
        "direct-api-spec",
        detached: true,
        command: ["/bin/sh", "-c", "printf 'TMUX_DIRECT_SESSION_READY'; sleep 5"]
      )
      pane = session.active_window.active_pane
      found_session = false
      deadline = Time.instant + 3.seconds
      while Time.instant < deadline
        if pane.capture_pane.join("\n").includes?("TMUX_DIRECT_SESSION_READY")
          found_session = true
          break
        end
        sleep 25.milliseconds
      end
      found_session.should be_true

      split = pane.split(
        :right,
        detached: true,
        command: ["/bin/sh", "-c", "printf 'TMUX_DIRECT_SPLIT_READY'; sleep 5"]
      )
      found_split = false
      deadline = Time.instant + 3.seconds
      while Time.instant < deadline
        if split.capture_pane.join("\n").includes?("TMUX_DIRECT_SPLIT_READY")
          found_split = true
          break
        end
        sleep 25.milliseconds
      end
      found_split.should be_true
    ensure
      begin
        server.kill_server
      rescue Tmux::Error
      end
    end
  end
end
