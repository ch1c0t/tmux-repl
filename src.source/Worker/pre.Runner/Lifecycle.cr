private def prepare_startup : Nil
  File.delete(@startup_error_path) if File.exists?(@startup_error_path)
  write_startup_stage("connecting to LavinMQ")
end

private def install_shutdown_handler : Nil
  Process.on_terminate do |_reason|
    @shutdown.send(nil)
  end
end

private def start_pty : Nil
  write_startup_stage("starting PTY session")
  @session.start
end

private def advertise_ready : Nil
  File.write(@ready_path, Process.pid.to_s)
  File.delete(@startup_stage_path) if File.exists?(@startup_stage_path)
end

private def wait_for_tmux_session(server : Tmux::Server) : Nil
  # The worker belongs to the tmux session, not to a pane or client.
  # Detaching therefore leaves the worker running.
  loop do
    sleep 5.seconds
    break unless server.cmd("has-session", "-t", @tmux_session_id).success?

    select
    when @shutdown.receive
      break
    when timeout(250.milliseconds)
    end
  end
end

private def tmux_server : Tmux::Server
  ENV["TMUX"]?.nil? ? Tmux::Server.new : Tmux::Server.from_env
end

private def write_startup_stage(stage : String) : Nil
  File.write(@startup_stage_path, stage)
end

private def report_startup_error(exception : Exception) : Nil
  File.write(@startup_error_path, "#{exception.class}: #{exception.message}")
  STDERR.puts "tmux.repl.worker: #{exception.class}: #{exception.message}"
end

private def cleanup : Nil
  begin
    @session.terminate
  rescue
  end
  File.delete(@ready_path) if File.exists?(@ready_path)
end
