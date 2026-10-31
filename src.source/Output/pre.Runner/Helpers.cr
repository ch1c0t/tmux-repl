private def state_dir : String
  base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
  File.join(base, "tmux-repl", @session_name)
end

private def output_pid_path : String
  File.join(state_dir, "output.pid")
end

private def startup_error_path : String
  File.join(state_dir, "output.error")
end

private def startup_stage_path : String
  File.join(state_dir, "output.startup")
end

private def prepare_startup : Nil
  File.delete(startup_error_path) if File.exists?(startup_error_path)
  update_startup_stage("connecting to LavinMQ")
end

private def update_startup_stage(stage : String) : Nil
  File.write(startup_stage_path, stage)
end

private def mark_ready : Nil
  File.write(output_pid_path, Process.pid.to_s)
  File.delete(startup_stage_path) if File.exists?(startup_stage_path)
end

private def report_startup_failure(exception : Exception) : Nil
  File.write(startup_error_path, "#{exception.class}: #{exception.message}")
  STDERR.puts "tmux.repl.output: #{exception.class}: #{exception.message}"
end

private def unsubscribe(
  event_queue : AMQP::Client::Queue?,
  consumer_tag : String?
) : Nil
  return unless queue = event_queue
  return unless tag = consumer_tag

  begin
    queue.unsubscribe(tag)
  rescue
  end
end

private def cleanup_readiness : Nil
  File.delete(output_pid_path) if File.exists?(output_pid_path)
end
