def cmd(*args : String) : CommandResult
  @server.cmd(*args)
end

def run!(*args : String) : CommandResult
  @server.run!(*args)
end

def window : Window
  Window.new(@server, @session_id, @window_id)
end

def session : Session
  Session.new(@server, @session_id)
end

def pane_index : Int32
  formatted_value("\#{pane_index}").to_i
end

def current_command : String
  formatted_value("\#{pane_current_command}")
end

def current_path : String
  formatted_value("\#{pane_current_path}")
end

def width : Int32
  formatted_value("\#{pane_width}").to_i
end

def height : Int32
  formatted_value("\#{pane_height}").to_i
end

def active? : Bool
  window.active_pane.pane_id == @pane_id
end

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
  id = @server.run!(*args).stdout.strip
  raise Error.new("tmux did not return a pane ID") if id.empty?
  Pane.new(@server, @session_id, @window_id, id)
end

def send_keys(keys : String, enter : Bool = true, literal : Bool = false) : Pane
  if literal
    @server.run!("send-keys", "-t", @pane_id, "-l", keys)
    @server.run!("send-keys", "-t", @pane_id, "Enter") if enter
  else
    args = ["send-keys", "-t", @pane_id, keys]
    args << "Enter" if enter
    @server.run!(*args)
  end
  self
end

def enter : Pane
  @server.run!("send-keys", "-t", @pane_id, "Enter")
  self
end

def capture_pane(start : String? = nil, finish : String? = nil, escape_sequences : Bool = false, join_wrapped : Bool = false) : Array(String)
  args = ["capture-pane", "-p", "-t", @pane_id]
  args.concat(["-S", start]) if start
  args.concat(["-E", finish]) if finish
  args << "-e" if escape_sequences
  args << "-J" if join_wrapped
  @server.run!(*args).stdout_lines
end

def display_message(format : String) : String
  formatted_value(format)
end

def select : Pane
  @server.run!("select-pane", "-t", @pane_id)
  self
end

def resize(width : Int32? = nil, height : Int32? = nil) : Pane
  raise ArgumentError.new("Specify width, height, or both") unless width || height
  args = ["resize-pane", "-t", @pane_id]
  args.concat(["-x", width.to_s]) if width
  args.concat(["-y", height.to_s]) if height
  @server.run!(*args)
  self
end

def clear_history : Pane
  @server.run!("clear-history", "-t", @pane_id)
  self
end

def kill : CommandResult
  @server.run!("kill-pane", "-t", @pane_id)
end
