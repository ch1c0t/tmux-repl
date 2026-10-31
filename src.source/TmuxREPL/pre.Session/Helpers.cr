private def amqp_environment : Hash(String, String)
  socket_path = ENV["LAVINMQ_AMQP_UNIXSOCKET"]?
  raise "Missing critical environment configuration variable: LAVINMQ_AMQP_UNIXSOCKET" unless socket_path

  environment = {"LAVINMQ_AMQP_UNIXSOCKET" => socket_path}
  environment.merge!(@environment)
  if TmuxREPL.trace_timing_enabled?
    environment["TMUX_REPL_TRACE_TIMING"] = "1"
    environment["TMUX_REPL_TRACE_FILE"] = File.join(state_dir, "timing.log")
  end
  environment
end

private def state_dir : String
  base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
  File.join(base, "tmux-repl", @name)
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
