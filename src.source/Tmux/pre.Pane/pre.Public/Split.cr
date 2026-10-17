def split(direction : Symbol = :right, size : Int32? = nil, start_directory : String? = nil, detached : Bool = true) : Pane
  args = ["split-window", "-P", "-F", "\#{pane_id}", "-t", @pane_id]
  case direction
  when :right
    args << "-h"
  when :left
    args.concat(["-h", "-b"])
  when :below
    args << "-v"
  when :above
    args.concat(["-v", "-b"])
  else
    raise ArgumentError.new("direction must be :right, :left, :above, or :below")
  end
  args << "-d" if detached
  args.concat(["-l", size.to_s]) if size
  args.concat(["-c", start_directory]) if start_directory
  id = @server.run!(args).stdout.strip
  raise Error.new("tmux did not return a pane ID") if id.empty?
  Pane.new(@server, @session_id, @window_id, id)
end
