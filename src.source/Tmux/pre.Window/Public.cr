def cmd(*args : String) : CommandResult
  @server.cmd(*args)
end

def run!(*args : String) : CommandResult
  @server.run!(*args)
end

def session : Session
  Session.new(@server, @session_id)
end

def window_name : String
  formatted_value("\\#{window_name}")
end

def window_index : Int32
  formatted_value("\\#{window_index}").to_i
end

def active? : Bool
  session.active_window.window_id == @window_id
end

def panes : Array(Pane)
  format = "\\#{pane_id}"
  result = @server.run!("list-panes", "-t", @window_id, "-F", format)
  result.stdout_lines.reject(&.empty?).map { |id| Pane.new(@server, @session_id, @window_id, id) }
end

def active_pane : Pane
  id = @server.run!("display-message", "-p", "-t", @window_id, "\\#{pane_id}").stdout.strip
  panes.each { |item| return item if item.pane_id == id }
  raise Error.new("Window #{@window_id} has no active pane")
end

def split(
  direction : Symbol = :right,
  size : Int32? = nil,
  start_directory : String? = nil,
  detached : Bool = true,
  command : Array(String)? = nil
) : Pane
  active_pane.split(direction, size, start_directory, detached, command)
end

def rename(name : String) : Window
  @server.run!("rename-window", "-t", @window_id, name)
  self
end

def select_layout(layout : String) : Window
  @server.run!("select-layout", "-t", @window_id, layout)
  self
end

def resize(width : Int32? = nil, height : Int32? = nil) : Window
  raise ArgumentError.new("Specify width, height, or both") unless width || height
  args = ["resize-window", "-t", @window_id]
  args.concat(["-x", width.to_s]) if width
  args.concat(["-y", height.to_s]) if height
  @server.run!(*args)
  self
end

def kill : CommandResult
  @server.run!("kill-window", "-t", @window_id)
end
