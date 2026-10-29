def start(focus : Bool = true) : Nil
  server = current_server
  if session = find_session(server)
    configure_lifecycle(session)
    activate(session) if focus
  else
    create_session(server, focus)
  end
end

include CreateSession

private def current_server : Tmux::Server
  return Tmux::Server.new if ENV["TMUX"]?.nil?
  Tmux::Server.from_env
end

private def find_session(server : Tmux::Server) : Tmux::Session?
  return nil unless server.cmd("has-session", "-t", @name).success?
  server.session(@name)
end

private def activate(session : Tmux::Session) : Nil
  if ENV["TMUX"]?.nil?
    session.attach
  else
    session.switch_client
  end
end
