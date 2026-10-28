private def create_session(server : Tmux::Server, focus : Bool) : Nil
  dir = state_dir
  session : Tmux::Session? = nil
  worker_process : Process? = nil

  begin
    FileUtils.mkdir_p(dir)

    created = if @command
      File.write(File.join(dir, "output.log"), "")
      server.new_session(name: @name, detached: true)
    else
      server.new_session(
        name: @name,
        detached: true,
        command: [repl_executable, "--repl", @name]
      )
    end
    session = created

    unless @command
      ready_path = File.join(dir, "worker.pid")
      File.delete(ready_path) if File.exists?(ready_path)
      worker_process = Process.new(
        worker_executable,
        ["--worker", @name],
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )
      wait_for_worker(ready_path)
    end

    configure_session(created)
    activate(created) if focus
  rescue ex
    if process = worker_process
      begin
        Process.signal(Signal::TERM, process.pid)
        process.wait
      rescue
      end
    end
    cleanup_failed_start(server, session, dir)
    STDERR.puts "tmux.repl: #{ex.message}"
    raise ex
  end
end

private def wait_for_worker(ready_path : String) : Nil
  deadline = Time.instant + 5.seconds
  while Time.instant < deadline
    return if File.exists?(ready_path)
    sleep 10.milliseconds
  end

  raise "Timed out waiting for tmux.repl.input to become ready"
end

private def configure_session(session : Tmux::Session) : Nil
  window = session.active_window
  input_pane = window.active_pane

  if @command
    log = File.join(state_dir, "output.log")
    input_pane.run!("pipe-pane", "-o", "-t", input_pane.pane_id, "cat >> #{shell_quote(log)}")
    input_pane.split(
      :right,
      detached: true,
      command: [show_executable, "--log", log]
    )
    input_pane.send_keys(input_command, literal: true)
  else
    input_pane.split(
      :right,
      detached: true,
      command: [show_executable, @name]
    )
  end

  window.select_layout("even-horizontal")
  input_pane.select
end

private def input_command : String
  @command.not_nil!.map { |argument| shell_quote(argument) }.join(" ")
end

private def cleanup_failed_start(server : Tmux::Server, session : Tmux::Session?, dir : String) : Nil
  begin
    if active_session = session
      active_session.kill
    else
      server.cmd("kill-session", "-t", @name)
    end
  rescue Tmux::Error
  end
  FileUtils.rm_rf(dir)
end
