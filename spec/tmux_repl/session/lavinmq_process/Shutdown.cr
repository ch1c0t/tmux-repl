module LavinMQProcess
  class Scenario
    private def stop_worker : Nil
      tmux_session.kill
      @repl_started = false
      # The worker checks whether its Tmux session still exists every five seconds.
      wait_until(7.seconds, 50.milliseconds) { !File.exists?(@worker_pid_path) }.should be_true
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
