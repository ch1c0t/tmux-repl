module LavinMQProcess
  module Shutdown
    private def stop_worker : Nil
      tmux_session.kill
      @repl_started = false

      # The worker checks whether its Tmux session still exists every five seconds.
      stopped = wait_until(7.seconds, 50.milliseconds) { !File.exists?(@worker_pid_path) }
      return if stopped

      fail_with_diagnostics(
        "The worker did not remove its PID file within 7 seconds after the Tmux session was killed.\n" \
        "Worker PID file: #{@worker_pid_path} (#{file_state(@worker_pid_path)})."
      )
    end

    private def cleanup : Nil
      begin
        @repl.stop if @repl_started
      ensure
        begin
          stop_tmux_server(@server) if @bootstrap_started
        ensure
          @previous_environment.each { |key, value| ENV[key] = value }
          FileUtils.rm_rf(@state_home)
        end
      end
    end
  end
end
