def cmd(*args : String) : CommandResult
  @server.cmd(*args)
end

def run!(*args : String) : CommandResult
  @server.run!(*args)
end

def session_name : String
  formatted_value("\#{session_name}")
end

def windows : Array(Window)
  format = "\#{window_id}"
  output = @server.run!("list-windows", "-t", @session_id, "-F", format)
  output.stdout_lines.reject(&.empty?).map { |id| Window.new(@server, @session_id, id) }
end

def active_window : Window
  id = formatted_value("\#{window_id}")
  windows.each { |item| return item if item.window_id == id }
  raise Error.new("Session #{@session_id} has no active window")
end

def new_window(name : String? = nil, detached : Bool = true, start_directory : String? = nil) : Window
  args = ["new-window", "-t", @session_id, "-P", "-F", "\#{window_id}"]
  args << "-d" if detached
  args.concat(["-n", name]) if name
  args.concat(["-c", start_directory]) if start_directory
  id = @server.run!(*args).stdout.strip
  raise Error.new("tmux did not return a window ID") if id.empty?
  Window.new(@server, @session_id, id)
end

def rename(name : String) : Session
  @server.run!("rename-session", "-t", @session_id, name)
  self
end

def attach(unset_tmux : Bool = false) : Nil
  @server.client.interactive!("attach-session", "-t", @session_id, unset_tmux: unset_tmux)
end

def kill : CommandResult
  @server.run!("kill-session", "-t", @session_id)
end
