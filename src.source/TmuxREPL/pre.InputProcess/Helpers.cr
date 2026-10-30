private def state_dir : String
  base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
  File.join(base, "tmux-repl", @session_name)
end

private def input_pid_path : String
  File.join(state_dir, "input.pid")
end

private def startup_error_path : String
  File.join(state_dir, "input.error")
end

private def startup_stage_path : String
  File.join(state_dir, "input.startup")
end

private def prepare_startup : Nil
  File.delete(startup_error_path) if File.exists?(startup_error_path)
  update_startup_stage("connecting to LavinMQ")
end

private def update_startup_stage(stage : String) : Nil
  File.write(startup_stage_path, stage)
end

private def report_startup_failure(exception : Exception) : Nil
  File.write(startup_error_path, "#{exception.class}: #{exception.message}")
  STDERR.puts "tmux.repl.input: #{exception.class}: #{exception.message}"
end

private def cleanup_readiness : Nil
  File.delete(input_pid_path) if File.exists?(input_pid_path)
end
