def stop(state_directory : String? = nil) : Nil
  dir = state_directory || state_dir
  stop_worker(dir)

  begin
    server = ENV["TMUX"]?.nil? ? Tmux::Server.new : Tmux::Server.from_env
    server.cmd("kill-session", "-t", "=#{@name}")
  rescue Tmux::Error
  ensure
    FileUtils.rm_rf(dir)
  end
end

# Called by the session-closed hook. It deliberately does not issue
# kill-session again, so direct tmux kills cannot recursively trigger stop.
def cleanup_after_session_close(state_directory : String) : Nil
  stop_worker(state_directory)
  FileUtils.rm_rf(state_directory)
end

private def stop_worker(dir : String = state_dir) : Nil
  ready_path = File.join(dir, "worker.pid")
  return unless File.exists?(ready_path)

  pid = File.read(ready_path).strip.to_i64?
  return unless pid

  begin
    Process.signal(Signal::TERM, pid)
  rescue
    return
  end

  deadline = Time.instant + 2.seconds
  while File.exists?(ready_path) && Time.instant < deadline
    sleep 10.milliseconds
  end

  if File.exists?(ready_path)
    begin
      Process.signal(Signal::KILL, pid)
    rescue
    end
  end
end
