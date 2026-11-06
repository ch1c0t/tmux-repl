private def amqp_environment : Hash(String, String)
  socket_path = ENV["LAVINMQ_AMQP_UNIXSOCKET"]?
  raise "Missing critical environment configuration variable: LAVINMQ_AMQP_UNIXSOCKET" unless socket_path

  environment = {"LAVINMQ_AMQP_UNIXSOCKET" => socket_path}
  environment.merge!(@environment)
  environment["TMUX_REPL_SESSION_NAME"] = @name
  environment["TMUX_REPL_SESSION_STATE"] = @state.base_path

  unless environment.has_key?("XDG_STATE_HOME")
    if state_home = ENV["XDG_STATE_HOME"]?
      environment["XDG_STATE_HOME"] = state_home
    end
  end

  unless environment.has_key?("LOG_LEVEL")
    if log_level = ENV["LOG_LEVEL"]?
      environment["LOG_LEVEL"] = log_level
    end
  end

  if TmuxREPL.trace_timing_enabled?
    environment["TMUX_REPL_TRACE_TIMING"] = "1"
    environment["TMUX_REPL_TRACE_FILE"] = @state.log_path("timing.log")
  end
  environment
end

private def state_dir : String
  @state.base_path
end

private def session_environment : Hash(String, String)
  environment = @environment.dup
  environment["TMUX_REPL_SESSION_NAME"] = @name
  environment["TMUX_REPL_SESSION_STATE"] = @state.base_path
  environment
end

private def resolved_input_executable : String
  override = @input_executable || ENV["TMUX_REPL_INPUT_EXECUTABLE"]?
  CompanionExecutable.resolve("tmux.repl.input", PROGRAM_NAME, override)
end

private def resolved_output_executable : String
  override = @output_executable || ENV["TMUX_REPL_OUTPUT_EXECUTABLE"]?
  CompanionExecutable.resolve("tmux.repl.output", PROGRAM_NAME, override)
end

private def resolved_worker_executable : String
  override = @worker_executable || ENV["TMUX_REPL_WORKER_EXECUTABLE"]?
  CompanionExecutable.resolve("tmux.repl.worker", PROGRAM_NAME, override)
end

private def shell_quote(value : String) : String
  "'#{value.gsub("'", "'\\''")}'"
end
