def cmd(*args : String) : CommandResult
  @client.run(*args)
end

include Run
include NewSession

def sessions : Array(Session)
  session_ids.map { |id| Session.new(self, id) }
end

def session(selector : String) : Session
  sessions.each do |item|
    return item if item.session_id == selector || item.session_name == selector
  end
  raise Error.new("No tmux session matches #{selector.inspect}")
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
