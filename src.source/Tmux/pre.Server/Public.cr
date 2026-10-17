def cmd(*args : String) : CommandResult
  @client.run(*args)
end

def run!(*args : String) : CommandResult
  @client.run!(*args)
end

def sessions : Array(Session)
  session_ids.map { |id| Session.new(self, id) }
end

def session(selector : String) : Session
  sessions.each do |item|
    return item if item.session_id == selector || item.session_name == selector
  end
  raise Error.new("No tmux session matches #{selector.inspect}")
end

def new_session(name : String? = nil, detached : Bool = true, window_name : String? = nil, start_directory : String? = nil) : Session
  args = ["new-session", "-d", "-P", "-F", "\#{session_id}"]
  args.concat(["-s", name]) if name
  args.concat(["-n", window_name]) if window_name
  args.concat(["-c", start_directory]) if start_directory
  id = run!(*args).stdout.strip
  raise Error.new("tmux did not return a session ID") if id.empty?
  session = Session.new(self, id)
  session.attach unless detached
  session
end

def windows : Array(Window)
  result = [] of Window
  sessions.each { |item| result.concat(item.windows) }
  result
end

def panes : Array(Pane)
  result = [] of Pane
  windows.each { |item| result.concat(item.panes) }
  result
end

def kill_server : CommandResult
  run!("kill-server")
end
