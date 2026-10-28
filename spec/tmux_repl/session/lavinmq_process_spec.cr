require "./helper"

describe "LavinMQ-backed REPL processes" do
  it "runs the Reply input app and PTY worker as separate processes" do
    name = "repl_lavinmq_spec_#{Process.pid}"
    state_home = File.join(ENV["TMPDIR"]? || "/tmp", "tmux-repl-lavinmq-#{Process.pid}")
    worker_pid_path = File.join(state_home, "tmux-repl", name, "worker.pid")
    previous_state_home = ENV["XDG_STATE_HOME"]?
    previous_path = ENV["PATH"]?
    ENV["XDG_STATE_HOME"] = state_home
    ENV["PATH"] = "#{File.expand_path("bin")}:#{previous_path || ""}"
    repl = TmuxREPL::Session.new(name)
    started = false

    begin
      repl.start(focus: false)
      started = true

      deadline = Time.instant + 5.seconds
      until File.exists?(worker_pid_path)
        raise "PTY worker did not become ready" if Time.instant >= deadline
        sleep 10.milliseconds
      end

      server = Tmux::Server.new
      tmux_session = server.session(name)
      panes = tmux_session.active_window.panes
      panes.size.should eq(2)
      input_pane = panes[0]
      output_pane = panes[1]

      input_pane.send_keys("printf 'TMUX_REPL_LAVINMQ_E2E'", literal: true)

      found = false
      deadline = Time.instant + 5.seconds
      while Time.instant < deadline
        if output_pane.capture_pane.join("\n").includes?("TMUX_REPL_LAVINMQ_E2E")
          found = true
          break
        end
        sleep 25.milliseconds
      end
      unless found
        diagnostics = "input pane:\n#{input_pane.capture_pane.join("\n")}\n" \
                      "output pane:\n#{output_pane.capture_pane.join("\n")}"
        begin
          channel = Global.amqp_channel
          command_queue = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(name))
          event_queue = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(name))
          diagnostics += "\ncommand stream messages: #{command_queue.message_count}"
          diagnostics += "\nevent stream messages: #{event_queue.message_count}"
        rescue ex
          diagnostics += "\nqueue diagnostics failed: #{ex.message}"
        end
        raise "REPL command did not reach output pane.\n#{diagnostics}"
      end
      output_pane.capture_pane.join("\n").should contain("[exit status: 0]")
    ensure
      repl.stop if started
      ENV["XDG_STATE_HOME"] = previous_state_home
      ENV["PATH"] = previous_path
      FileUtils.rm_rf(state_home)
    end
  end
end
