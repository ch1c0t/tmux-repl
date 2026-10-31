require "./helper"

private def lavinmq_diagnostics(
  session_name : String,
  input_pane : Tmux::Pane,
  output_pane : Tmux::Pane
) : String
  details = "input pane:\n#{pane_text(input_pane)}\noutput pane:\n#{pane_text(output_pane)}"

  begin
    channel = Global.amqp_channel
    commands = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(session_name))
    events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(session_name))
    details += "\ncommand stream messages: #{commands.message_count}"
    details += "\nevent stream messages: #{events.message_count}"
  rescue ex
    details += "\nqueue diagnostics failed: #{ex.message}"
  end

  details
end

describe "LavinMQ-backed REPL processes" do
  it "streams raw output, switches to the stripped result, and toggles back" do
    name = "repl_lavinmq_spec_#{Process.pid}"
    state_home = File.join(ENV["TMPDIR"]? || "/tmp", "tmux-repl-lavinmq-#{Process.pid}")
    state_dir = File.join(state_home, "tmux-repl", name)
    worker_pid_path = File.join(state_dir, "worker.pid")
    ready_paths = %w[input.pid worker.pid output.pid].map { |file| File.join(state_dir, file) }

    previous_environment = {
      "XDG_STATE_HOME" => ENV["XDG_STATE_HOME"]?,
      "PATH"           => ENV["PATH"]?,
      "TMUX"           => ENV["TMUX"]?,
    }
    bin_dir = File.expand_path("bin")
    tmux_socket_path = File.join(state_home, "tmux.sock")
    bootstrap_name = "repl_path_bootstrap_#{Process.pid}"
    server = Tmux::Server.new(socket_path: tmux_socket_path)
    repl = TmuxREPL::Session.new(name)
    bootstrap_started = false
    repl_started = false

    begin
      ENV["XDG_STATE_HOME"] = state_home
      FileUtils.mkdir_p(state_home)

      # Start tmux before adding bin/ to PATH to reproduce a daemon with a stale PATH.
      ENV["PATH"] = "/usr/bin:/bin"
      ENV.delete("TMUX")
      server.new_session(name: bootstrap_name, detached: true)
      bootstrap_started = true

      ENV["TMUX"] = "#{tmux_socket_path},#{Process.pid},0,0,0"
      ENV["PATH"] = "#{bin_dir}:#{previous_environment["PATH"] || ""}"

      repl.start(focus: false)
      repl_started = true

      ready_paths.each do |path|
        raise "REPL process did not become ready: #{path}" unless wait_for_file(path)
      end

      socket_path = ENV["LAVINMQ_AMQP_UNIXSOCKET"]?
      socket_path.should_not be_nil

      environment = server.cmd("show-environment", "-t", name, "LAVINMQ_AMQP_UNIXSOCKET")
      environment.success?.should be_true
      environment.stdout.strip.should eq("LAVINMQ_AMQP_UNIXSOCKET=#{socket_path}")

      tmux_session = server.session(name)
      panes = tmux_session.active_window.panes
      panes.size.should eq(2)
      input_pane = panes[0]
      output_pane = panes[1]

      input_pane.send_keys("printf 'FIRST_REPL_OUTPUT\\n'", literal: true)
      pane_shows?(
        output_pane,
        ["FIRST_REPL_OUTPUT", "[exit status: 0]"],
        5.seconds,
        25.milliseconds
      ).should be_true

      pane_shows?(
        input_pane,
        ["[input #1] submitted", "$:002>"],
        5.seconds,
        25.milliseconds
      ).should be_true

      input_pane.send_keys("printf 'SECOND_REPL_OUTPUT\\n'", literal: true)
      second_completed = pane_shows?(
        output_pane,
        ["SECOND_REPL_OUTPUT", "[exit status: 0]"],
        5.seconds,
        25.milliseconds
      )
      unless second_completed
        raise "Second command did not complete.\n#{lavinmq_diagnostics(name, input_pane, output_pane)}"
      end

      input_pane.send_keys(":prev", literal: true)
      pane_shows?(
        output_pane,
        ["INPUT #1", "FIRST_REPL_OUTPUT", "[exit status: 0]"],
        5.seconds,
        25.milliseconds
      ).should be_true
      pane_text(output_pane).should_not contain("SECOND_REPL_OUTPUT")

      input_pane.send_keys(":next", literal: true)
      pane_shows?(
        output_pane,
        ["INPUT #2", "SECOND_REPL_OUTPUT", "[exit status: 0]"],
        5.seconds,
        25.milliseconds
      ).should be_true

      input_pane.send_keys(":list", literal: true)
      pane_shows?(
        input_pane,
        ["#1: printf", "* #2: printf"],
        5.seconds,
        25.milliseconds
      ).should be_true

      input_pane.send_keys(":help", literal: true)
      pane_shows?(
        input_pane,
        [":select ID", ":prev", ":next", ":list"],
        5.seconds,
        25.milliseconds
      ).should be_true

      input_pane.send_keys(":select 1", literal: true)
      pane_shows?(
        output_pane,
        ["INPUT #1", "FIRST_REPL_OUTPUT", "[exit status: 0]"],
        5.seconds,
        25.milliseconds
      ).should be_true
      pane_text(output_pane).should_not contain("SECOND_REPL_OUTPUT")

      input_pane.send_keys(
        %(for i in $(seq 1 4); do echo "Streaming Tick $i..." && sleep 0.2; done),
        literal: true
      )
      pane_shows?(
        output_pane,
        ["Streaming Tick 1...", "START_MARK_"],
        3.seconds,
        25.milliseconds
      ).should be_true

      raw_while_running = pane_text(output_pane)
      raw_while_running.should contain("END_MARK_")
      raw_while_running.should contain("Streaming Tick 1...")

      pane_shows?(
        output_pane,
        ["Streaming Tick 4...", "[exit status: 0]"],
        5.seconds,
        25.milliseconds
      ).should be_true

      stripped_after_completion = pane_text(output_pane)
      stripped_after_completion.should_not contain("START_MARK_")
      stripped_after_completion.should_not contain("END_MARK_")
      stripped_after_completion.should contain("Streaming Tick 1...")
      stripped_after_completion.should contain("Streaming Tick 4...")

      # The same Ctrl+G shortcut works from the input pane.
      input_pane.send_keys("C-g")
      pane_shows?(
        output_pane,
        ["START_MARK_", "END_MARK_"],
        2.seconds,
        25.milliseconds
      ).should be_true

      # It also works from the output pane, toggling back to the stripped view.
      output_pane.send_keys("C-g")
      pane_shows?(
        output_pane,
        ["Streaming Tick 4...", "[exit status: 0]"],
        2.seconds,
        25.milliseconds
      ).should be_true
      pane_text(output_pane).should_not contain("START_MARK_")
      pane_text(output_pane).should_not contain("END_MARK_")

      # Killing the tmux session directly must also stop the independent worker.
      tmux_session.kill
      repl_started = false
      # The worker checks whether its session still exists every five seconds.
      wait_until(7.seconds, 50.milliseconds) { !File.exists?(worker_pid_path) }.should be_true
    ensure
      repl.stop if repl_started
      stop_tmux_server(server) if bootstrap_started
      previous_environment.each { |key, value| ENV[key] = value }
      FileUtils.rm_rf(state_home)
    end
  end
end
