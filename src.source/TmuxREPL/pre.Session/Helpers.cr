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

# Prefer companions built or installed beside this CLI executable. When the
# library is hosted by another program, fall back to the executable name so
# the caller's PATH remains authoritative; never guess from the caller's CWD.
private def input_executable : String
  CompanionExecutable.resolve("tmux.repl.input", PROGRAM_NAME)
end

private def output_executable : String
  CompanionExecutable.resolve("tmux.repl.output", PROGRAM_NAME)
end

private def worker_executable : String
  CompanionExecutable.resolve("tmux.repl.worker", PROGRAM_NAME)
end

private def shell_quote(value : String) : String
  "'#{value.gsub("'", "'\\''")}'"
end
