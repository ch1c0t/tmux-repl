def new_session(name : String? = nil, detached : Bool = true, window_name : String? = nil, start_directory : String? = nil) : Session
  # 1. Initialize as a true Array using [...]
  args = ["new-session", "-d", "-P", "-F", "\#{session_id}"]
  args.concat(["-s", name]) if name
  args.concat(["-n", window_name]) if window_name
  args.concat(["-c", start_directory]) if start_directory

  # 2. Pass the array directly without the '*'
  id = run!(args).stdout.strip

  raise Error.new("tmux did not return a session ID") if id.empty?
  session = Session.new(self, id)
  session.attach unless detached
  session
end
