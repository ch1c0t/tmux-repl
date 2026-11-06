def stop : Nil
  stop_worker

  begin
    server = ENV["TMUX"]?.nil? ? Tmux::Server.new : Tmux::Server.from_env
    server.cmd("kill-session", "-t", @name)
  rescue Tmux::Error
  ensure
    @state.cleanup_runtime
  end
end

private def stop_worker : Nil
  ready_path = @state.path("worker.pid")
  unless File.exists?(ready_path) || File.exists?(@state.manifest_path)
    legacy_path = State.legacy_path(@name)
    ready_path = File.join(legacy_path, "worker.pid")
  end
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
