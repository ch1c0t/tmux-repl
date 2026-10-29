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
    previous_tmux = ENV["TMUX"]?
    bin_dir = File.expand_path("bin")
    tmux_socket_path = File.join(state_home, "tmux.sock")
    bootstrap_name = "repl_path_bootstrap_#{Process.pid}"
    server = Tmux::Server.new(socket_path: tmux_socket_path)
    repl = TmuxREPL::Session.new(name)
    started = false
    bootstrap_started = false

    begin
      ENV["XDG_STATE_HOME"] = state_home
      FileUtils.mkdir_p(state_home)

      # Start an isolated tmux server before adding bin/ to PATH. The daemon
      # deliberately keeps this old PATH, like an interactive local tmux server.
      ENV["PATH"] = "/usr/bin:/bin"
      ENV.delete("TMUX")
      server.new_session(name: bootstrap_name, detached: true)
      bootstrap_started = true

      ENV["TMUX"] = "#{tmux_socket_path},#{Process.pid},0,0,0"
      ENV["PATH"] = "#{bin_dir}:#{previous_path || ""}"

      repl.start(focus: false)
      started = true

      [input_pid_path, worker_pid_path, output_pid_path].each do |ready_path|
        deadline = Time.instant + 5.seconds
        until File.exists?(ready_path)
          raise "REPL process did not become ready: #{ready_path}" if Time.instant >= deadline
          sleep 10.milliseconds
        end
      end

      socket_path = ENV["LAVINMQ_AMQP_UNIXSOCKET"]?
      socket_path.should_not be_nil
      session_environment = server.cmd("show-environment", "-t", name, "LAVINMQ_AMQP_UNIXSOCKET")
      session_environment.success?.should be_true
      session_environment.stdout.strip.should eq("LAVINMQ_AMQP_UNIXSOCKET=#{socket_path}")
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
      tmux_session.kill
      started = false

      cleanup_deadline = Time.instant + 3.seconds
      while File.exists?(worker_pid_path) && Time.instant < cleanup_deadline
        sleep 10.milliseconds
      end

      File.exists?(worker_pid_path).should be_false
      File.directory?(File.join(state_home, "tmux-repl", name)).should be_false
    ensure
      repl.stop if started
      if bootstrap_started
        begin
          server.kill_server
        rescue Tmux::Error
        end
      end
      ENV["XDG_STATE_HOME"] = previous_state_home
      ENV["PATH"] = previous_path
      ENV["TMUX"] = previous_tmux
      FileUtils.rm_rf(state_home)
    end
  end
end
