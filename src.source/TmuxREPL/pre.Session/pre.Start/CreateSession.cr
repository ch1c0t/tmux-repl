private def create_session(server : Tmux::Server, focus : Bool) : Nil
  dir = state_dir
  session : Tmux::Session? = nil

  begin
    FileUtils.mkdir_p(dir)
    created = server.new_session(name: @name, detached: true)
    session = created

    unless @command
      Process.new(
        worker_executable,
        ["--worker", @name],
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )
    end

    configure_session(created)
    activate(created) if focus
  rescue ex
    cleanup_failed_start(server, session, dir)
    STDERR.puts "tmux.repl: #{ex.message}"
    raise ex
  end
end

private def configure_session(session : Tmux::Session) : Nil
  window = session.active_window
  input_pane = window.active_pane
  output_pane = input_pane.split(:right, detached: true)
  window.select_layout("even-horizontal")

  input_pane.send_keys(input_command, literal: true)
  output_pane.send_keys("#{shell_quote(show_executable)} #{shell_quote(@name)}", literal: true)
  input_pane.select
end

private def input_command : String
  if command = @command
    command.map { |argument| shell_quote(argument) }.join(" ")
  else
    "#{shell_quote(repl_executable)} --repl #{shell_quote(@name)}"
  end
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
