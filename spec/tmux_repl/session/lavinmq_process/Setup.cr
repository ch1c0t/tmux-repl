module LavinMQProcess
  module Setup
    private def start : Nil
      ENV["XDG_STATE_HOME"] = @state_home
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
      @ready_paths.each do |path|
        raise "REPL process did not become ready: #{path}" unless wait_for_file(path)
      end

      socket_path = ENV["LAVINMQ_AMQP_UNIXSOCKET"]? || raise "LAVINMQ_AMQP_UNIXSOCKET is not set"
      environment = @server.cmd("show-environment", "-t", name, "LAVINMQ_AMQP_UNIXSOCKET")
      environment.success?.should be_true
      environment.stdout.strip.should eq("LAVINMQ_AMQP_UNIXSOCKET=#{socket_path}")

      @tmux_session = @server.session(name)
      panes = tmux_session.active_window.panes
      panes.size.should eq(2)
      @input_pane = panes[0]
      @output_pane = panes[1]
    end
  end
end
