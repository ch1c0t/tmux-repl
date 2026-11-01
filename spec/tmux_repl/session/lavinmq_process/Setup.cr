module LavinMQProcess
  module Setup
    private def start : Nil
      ENV["XDG_STATE_HOME"] = @state_home
      ENV["LOG_LEVEL"] = "TRACE"
      FileUtils.mkdir_p(@state_home)

      # Start tmux before adding bin/ to PATH: its daemon keeps the original PATH.
      ENV["PATH"] = "/usr/bin:/bin"
      ENV.delete("TMUX")
      @server.new_session(name: "repl_path_bootstrap_#{Process.pid}", detached: true)
      @bootstrap_started = true

      ENV["TMUX"] = "#{File.join(@state_home, "tmux.sock")},#{Process.pid},0,0,0"
      ENV["PATH"] = "#{File.expand_path("bin")}:#{@previous_environment["PATH"] || ""}"

      @repl.start(focus: false)
      @repl_started = true
      @ready_paths.each { |path| expect_ready_file(path) }

      socket_path = ENV["LAVINMQ_AMQP_UNIXSOCKET"]?
      unless socket_path
        fail_with_diagnostics("LAVINMQ_AMQP_UNIXSOCKET is not set in the test process.")
      end

      environment = @server.cmd("show-environment", "-t", name, "LAVINMQ_AMQP_UNIXSOCKET")
      expect_condition(
        environment.success?,
        "tmux could not read LAVINMQ_AMQP_UNIXSOCKET from session #{name}.\n" \
        "stdout: #{environment.stdout.inspect}\nstderr: #{environment.stderr.inspect}"
      )
      expect_equal(
        "LAVINMQ_AMQP_UNIXSOCKET=#{socket_path}",
        environment.stdout.strip,
        "The REPL tmux session did not inherit the LavinMQ socket environment variable."
      )

      session_name_environment = @server.cmd("show-environment", "-t", name, "TMUX_REPL_SESSION_NAME")
      expect_condition(
        session_name_environment.success? &&
          session_name_environment.stdout.strip == "TMUX_REPL_SESSION_NAME=#{name}",
        "The REPL tmux session did not receive TMUX_REPL_SESSION_NAME=#{name}.\n" \
        "stdout: #{session_name_environment.stdout.inspect}\nstderr: #{session_name_environment.stderr.inspect}"
      )

      log_level_environment = @server.cmd("show-environment", "-t", name, "LOG_LEVEL")
      expect_condition(
        log_level_environment.success? && log_level_environment.stdout.strip == "LOG_LEVEL=TRACE",
        "The REPL tmux session did not receive LOG_LEVEL=TRACE.\n" \
        "stdout: #{log_level_environment.stdout.inspect}\nstderr: #{log_level_environment.stderr.inspect}"
      )

      @tmux_session = @server.session(name)
      panes = tmux_session.active_window.panes
      expect_equal(
        2,
        panes.size,
        "Expected the REPL tmux window to contain exactly an input pane and an output pane."
      )
      @input_pane = panes[0]
      @output_pane = panes[1]
    end

    private def expect_ready_file(path : String, timeout : Time::Span = 5.seconds) : Nil
      return if wait_for_file(path, timeout)

      fail_with_diagnostics(
        "Timed out after #{timeout} waiting for a REPL process readiness file: #{path}.\n" \
        "The input, worker, and output processes should each create their PID file during startup."
      )
    end
  end
end
