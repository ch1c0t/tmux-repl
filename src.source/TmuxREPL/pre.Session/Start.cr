def start : Nil
  server = current_server
  if session = find_session(server)
    activate(session)
  else
    create_session(server)
  end
end

private def current_server : Tmux::Server
  return Tmux::Server.new if ENV["TMUX"]?.nil?
  Tmux::Server.from_env
end

private def find_session(server : Tmux::Server) : Tmux::Session?
  return nil unless server.cmd("has-session", "-t", @name).success?
  server.session(@name)
end

private def create_session(server : Tmux::Server) : Nil
  dir = state_dir
  session : Tmux::Session? = nil

  begin
    FileUtils.mkdir_p(dir)
    log = File.join(dir, "output.log")
    File.write(log, "")

    created = server.new_session(name: @name, detached: true)
    session = created
    configure_session(created, log)
    activate(created)
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

  input = "#{shell_quote(repl_executable)} --repl #{shell_quote(log)}"
  output = "#{shell_quote(show_executable)} #{shell_quote(log)}"
  input_pane.send_keys(input, literal: true)
  output_pane.send_keys(output, literal: true)
  input_pane.select
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

private def activate(session : Tmux::Session) : Nil
  if ENV["TMUX"]?.nil?
    session.attach
  else
    session.switch_client
  end
end
