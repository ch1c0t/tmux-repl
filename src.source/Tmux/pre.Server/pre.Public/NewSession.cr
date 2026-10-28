def new_session(
  name : String? = nil,
  detached : Bool = true,
  window_name : String? = nil,
  start_directory : String? = nil,
  command : Array(String)? = nil
) : Session
  args = ["new-session", "-d", "-P", "-F", "\#{session_id}"]
  args.concat(["-s", name]) if name
  args.concat(["-n", window_name]) if window_name
  args.concat(["-c", start_directory]) if start_directory
  args.concat(command) if command

  id = run!(args).stdout.strip

  raise Error.new("tmux did not return a session ID") if id.empty?
  session = Session.new(self, id)
  session.attach unless detached
  session
end
