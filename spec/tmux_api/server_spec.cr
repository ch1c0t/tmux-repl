require "../crystal_helper"

describe Tmux::Server do
  it "creates a session, splits to the right, sends keys, and captures output" do
    server = Tmux::Server.new("crystal_tmux_api_spec_#{Process.pid}")

    begin
      session = server.new_session("api-spec", detached: true, window_name: "main")
      session.session_name.should eq("api-spec")

      window = session.active_window
      window.window_name.should eq("main")

      pane = window.active_pane
      split = pane.split(:right, detached: true)
      split.window.window_id.should eq(window.window_id)

      left_position = pane.display_message("\#{pane_left}").to_i
      right_position = split.display_message("\#{pane_left}").to_i
      right_position.should be > left_position

      pane.send_keys("printf 'TMUX_API_READY'")
      pane_shows?(pane, ["TMUX_API_READY"], 3.seconds, 50.milliseconds).should be_true
    ensure
      stop_tmux_server(server)
    end
  end

  it "starts session and split-pane commands with explicit arguments" do
    server = Tmux::Server.new("crystal_tmux_direct_api_spec_#{Process.pid}")

    begin
      session = server.new_session(
        "direct-api-spec",
        detached: true,
        command: ["/bin/sh", "-c", "printf 'TMUX_DIRECT_SESSION_READY'; sleep 5"]
      )
      pane = session.active_window.active_pane
      pane_shows?(pane, ["TMUX_DIRECT_SESSION_READY"]).should be_true

      split = pane.split(
        :right,
        detached: true,
        command: ["/bin/sh", "-c", "printf 'TMUX_DIRECT_SPLIT_READY'; sleep 5"]
      )
      pane_shows?(split, ["TMUX_DIRECT_SPLIT_READY"]).should be_true
    ensure
      stop_tmux_server(server)
    end
  end
end
