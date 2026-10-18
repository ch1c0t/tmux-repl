private def create_session(server : Tmux::Server, focus : Bool) : Nil
  dir = state_dir
  session : Tmux::Session? = nil

  begin
    FileUtils.mkdir_p(dir)
    log = File.join(dir, "output.log")
    File.write(log, "")

    created = server.new_session(name: @name, detached: true)
    session = created
    configure_session(created, log)
    activate(created) if focus
  rescue ex
    cleanup_failed_start(server, session, dir)
    STDERR.puts "tmux.repl: #{ex.message}"
    raise ex
  end
end

private def configure_session(session : Tmux::Session, log : String) : Nil
  window = session.active_window
  input_pane = window.active_pane
  output_pane = input_pane.split(:right, detached: true)
  window.select_layout("even-horizontal")

  input = input_command(input_pane, log)
  output = "#{shell_quote(show_executable)} #{shell_quote(log)}"
  input_pane.send_keys(input, literal: true)
  output_pane.send_keys(output, literal: true)
  input_pane.select
end

private def input_command(pane : Tmux::Pane, log : String) : String
  if command = @command
    pane.run!("pipe-pane", "-o", "-t", pane.pane_id, "cat >> #{shell_quote(log)}")
    command.map { |argument| shell_quote(argument) }.join(" ")
  else
    "#{shell_quote(repl_executable)} --repl #{shell_quote(log)}"
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
