require "./helper"

describe "LavinMQ-backed REPL processes" do
  it "selects one input and displays only its associated output" do
    name = "repl_lavinmq_spec_#{Process.pid}"
    state_home = File.join(ENV["TMPDIR"]? || "/tmp", "tmux-repl-lavinmq-#{Process.pid}")
    worker_pid_path = File.join(state_home, "tmux-repl", name, "worker.pid")
    input_pid_path = File.join(state_home, "tmux-repl", name, "input.pid")
    output_pid_path = File.join(state_home, "tmux-repl", name, "output.pid")
    previous_state_home = ENV["XDG_STATE_HOME"]?
    previous_path = ENV["PATH"]?
    ENV["XDG_STATE_HOME"] = state_home
    ENV["PATH"] = "#{File.expand_path("bin")}:#{previous_path || ""}"
    repl = TmuxREPL::Session.new(name)
    started = false

    begin
      repl.start(focus: false)
      started = true

      [input_pid_path, worker_pid_path, output_pid_path].each do |ready_path|
        deadline = Time.instant + 5.seconds
        until File.exists?(ready_path)
          raise "REPL process did not become ready: #{ready_path}" if Time.instant >= deadline
          sleep 10.milliseconds
        end
      end

      server = Tmux::Server.new
      tmux_session = server.session(name)
      panes = tmux_session.active_window.panes
      panes.size.should eq(2)
      input_pane = panes[0]
      output_pane = panes[1]

      input_pane.send_keys("printf 'FIRST_REPL_OUTPUT\\n'", literal: true)

      first_completed = false
      deadline = Time.instant + 5.seconds
      while Time.instant < deadline
        visible = output_pane.capture_pane.join("\n")
        if visible.includes?("FIRST_REPL_OUTPUT") && visible.includes?("[exit status: 0]")
          first_completed = true
          break
        end
        sleep 25.milliseconds
      end
      first_completed.should be_true

      input_ready = false
      deadline = Time.instant + 5.seconds
      while Time.instant < deadline
        visible = input_pane.capture_pane.join("\n")
        if visible.includes?("[input #1] submitted") && visible.includes?("$:002>")
          input_ready = true
          break
        end
        sleep 25.milliseconds
      end
      input_ready.should be_true

      input_pane.send_keys("printf 'SECOND_REPL_OUTPUT\\n'", literal: true)

      second_completed = false
      deadline = Time.instant + 5.seconds
      while Time.instant < deadline
        visible = output_pane.capture_pane.join("\n")
        if visible.includes?("SECOND_REPL_OUTPUT") && visible.includes?("[exit status: 0]")
          second_completed = true
          break
        end
        sleep 25.milliseconds
      end
      unless second_completed
        visible_input = input_pane.capture_pane.join("\n")
        visible_output = output_pane.capture_pane.join("\n")
        diagnostics = "input pane:\n#{visible_input}\noutput pane:\n#{visible_output}"
        begin
          channel = Global.amqp_channel
          command_queue = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(name))
          event_queue = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(name))
          diagnostics += "\ncommand stream messages: #{command_queue.message_count}"
          diagnostics += "\nevent stream messages: #{event_queue.message_count}"
        rescue ex
          diagnostics += "\nqueue diagnostics failed: #{ex.message}"
        end
        raise "Second command did not complete.\n#{diagnostics}"
      end

      input_pane.send_keys(":select 1", literal: true)

      first_selected = false
      deadline = Time.instant + 5.seconds
      while Time.instant < deadline
        visible = output_pane.capture_pane.join("\n")
        if visible.includes?("INPUT #1") && visible.includes?("FIRST_REPL_OUTPUT") && visible.includes?("[exit status: 0]")
          first_selected = true
          break
        end
        sleep 25.milliseconds
      end
      first_selected.should be_true

      visible = output_pane.capture_pane.join("\n")
      visible.should_not contain("SECOND_REPL_OUTPUT")
    ensure
      repl.stop if started
      ENV["XDG_STATE_HOME"] = previous_state_home
      ENV["PATH"] = previous_path
      FileUtils.rm_rf(state_home)
    end
  end
end
