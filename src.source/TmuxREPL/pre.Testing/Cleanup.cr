private def finish : Nil
  if @output_pane
    cleanup_step("Restore Output pane zoom") { restore_output_zoom }
  end

  if @restore_client && @focus
    cleanup_step("Return to original session") { return_to_origin }
  end

  should_cleanup = @cleanup == :always || (@cleanup == :on_failure && !@failure.nil?)
  if should_cleanup && @session_name
    cleanup_step("Clean up REPL session") { cleanup_session }
  end
end

private def cleanup_step(name : String, &block : ->) : Nil
  started_at = Time.instant
  begin
    yield
    @report << {
      name: name,
      passed: true,
      duration_ms: (Time.instant - started_at).total_milliseconds,
      details: "",
    }
  rescue ex
    @report << {
      name: name,
      passed: false,
      duration_ms: (Time.instant - started_at).total_milliseconds,
      details: "#{ex.class}: #{ex.message}",
    }
    @failure ||= ex
  end
end

private def restore_output_zoom : Nil
  pane = @output_pane
  return unless pane
  return unless pane.display_message("\#{window_zoomed_flag}") == "1"

  pane.select
  pane.run!("resize-pane", "-Z", "-t", pane.pane_id)
end

private def return_to_origin : Nil
  @origin_session.switch_client
  restored = wait_until { current_client_session_name == @origin_session_name }
  raise "The Tmux client did not return to #{@origin_session_name.inspect}." unless restored
end

private def cleanup_session : Nil
  name = @session_name
  failure : Exception? = nil

  if definition = @definition
    begin
      definition.stop
    rescue ex
      failure = ex
      @server.cmd("kill-session", "-t", name.not_nil!) if name
    end

    begin
      wait_for_custom_host
    rescue ex
      failure ||= ex
    end
  else
    if name
      begin
        Session.new(name).stop
      rescue ex
        failure = ex
        @server.cmd("kill-session", "-t", name)
      end
    end

    begin
      stop_host_process
    rescue ex
      failure ||= ex
    end
  end

  if name
    removed = wait_until(@host_stop_timeout) do
      !@server.cmd("has-session", "-t", name).success?
    end
    failure ||= Exception.new("Tmux session #{name.inspect} was not removed.") unless removed
  end

  raise failure.not_nil! if failure
  @session_cleaned = true
end

private def wait_for_custom_host : Nil
  result = @definition_host_result || return
  message = ""

  select
  when value = result.receive
    message = value
  when timeout(@host_stop_timeout)
    raise "Timed out waiting for the in-process custom command host to stop."
  end

  raise "Custom command host failed: #{message}" unless message.empty?
end

private def host_exit_status(timeout : Time::Span) : Process::Status?
  return @host_status if @host_status

  channel = @host_exit || return nil
  select
  when status = channel.receive
    @host_status = status
  when timeout(timeout)
  end

  @host_status
end

private def raise_host_exit! : Nil
  status = host_exit_status(0.seconds)
  raise_host_exit!(status) if status
end

private def raise_host_exit!(status : Process::Status) : NoReturn
  close_host_log
  raise "Custom REPL host process exited with status #{status.exit_code}. #{host_diagnostics}"
end

private def stop_host_process : Nil
  process = @host_process
  unless process
    close_host_log
    return
  end

  status = host_exit_status(@host_stop_timeout)
  unless status
    begin
      process.terminate
    rescue
    end
    status = host_exit_status(@host_stop_timeout)
  end
  unless status
    begin
      process.terminate(graceful: false)
    rescue
    end
    status = host_exit_status(@host_stop_timeout)
  end

  unless status
    raise "Timed out waiting for custom REPL host process #{process.pid} to exit after termination. #{host_diagnostics}"
  end

  close_host_log
  raise "Custom REPL host exited with status #{status.exit_code}. #{host_diagnostics}" unless status.success?
end

private def close_host_log : Nil
  @host_log.try &.close
  @host_log = nil
end

private def host_diagnostics : String
  path = @host_log_path
  return "Host log unavailable." unless path

  contents = File.exists?(path) ? File.read(path).strip : ""
  contents.empty? ? "Host log: #{path}" : "Host log: #{path}\n#{contents}"
rescue ex
  "Could not read custom host log: #{ex.message}"
end
