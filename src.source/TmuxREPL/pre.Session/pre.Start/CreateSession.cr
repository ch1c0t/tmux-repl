private def create_session(server : Tmux::Server, focus : Bool) : Nil
  dir = state_dir
  session : Tmux::Session? = nil
  worker_process : Process? = nil

  begin
    FileUtils.mkdir_p(dir)
    unless @command
      File.write(File.join(dir, "input.startup"), "launching #{input_executable}")
    end

    created = if @command
      File.write(File.join(dir, "output.log"), "")
      server.new_session(name: @name, detached: true)
    else
      server.new_session(
        name: @name,
        detached: true,
        command: [input_executable, "--input", @name]
      )
    end
    session = created

    unless @command
      wait_for_ready(File.join(dir, "input.pid"), "tmux.repl.input")
      File.write(File.join(dir, "worker.startup"), "launching #{worker_executable}")
      worker_process = Process.new(
        worker_executable,
        ["--worker", @name],
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )
      wait_for_ready(File.join(dir, "worker.pid"), "tmux.repl.worker")
    end

    configure_session(created)

    unless @command
      wait_for_ready(File.join(dir, "output.pid"), "tmux.repl.output")
    end

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

private def wait_for_ready(path : String, process_name : String) : Nil
  error_path = path.sub(/\.pid$/, ".error")
  stage_path = path.sub(/\.pid$/, ".startup")
  deadline = Time.instant + 5.seconds

  while Time.instant < deadline
    if File.exists?(error_path)
      details = File.read(error_path).strip
      raise "#{process_name} failed before readiness: #{details}"
    end

    return if File.exists?(path)
    sleep 10.milliseconds
  end

  if File.exists?(error_path)
    details = File.read(error_path).strip
    raise "#{process_name} failed before readiness: #{details}"
  end

  stage = File.read(stage_path).strip if File.exists?(stage_path)
  detail = stage ? " while #{stage}" : ""
  raise "Timed out waiting for #{process_name} readiness at #{path}#{detail}"
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
      command: [output_executable, "--log", log]
    )
    input_pane.send_keys(input_command, literal: true)
  else
    File.write(File.join(state_dir, "output.startup"), "launching #{output_executable}")
    input_pane.split(
      :right,
      detached: true,
      command: [output_executable, @name]
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
