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
  it "shows only the output associated with the selected input" do
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

      session = server.session(name)
      panes = session.active_window.panes
      panes.size.should eq(2)
      input_pane, output_pane = panes

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

      input_pane.send_keys(":select 1", literal: true)
      pane_shows?(
        output_pane,
        ["INPUT #1", "FIRST_REPL_OUTPUT", "[exit status: 0]"],
        5.seconds,
        25.milliseconds
      ).should be_true
      pane_text(output_pane).should_not contain("SECOND_REPL_OUTPUT")

      # Killing the tmux session directly must also stop the independent worker.
      session.kill
      repl_started = false
      wait_until(3.seconds, 10.milliseconds) { !File.exists?(worker_pid_path) }.should be_true
    ensure
      repl.stop if repl_started
      stop_tmux_server(server) if bootstrap_started
      previous_environment.each { |key, value| ENV[key] = value }
      FileUtils.rm_rf(state_home)
    end
  end
end
