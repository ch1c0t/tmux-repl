include Split
include SendKeys
include CapturePane
include Resize

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

def enter : Pane
  @server.run!("send-keys", "-t", @pane_id, "Enter")
  self
end


def display_message(format : String) : String
  formatted_value(format)
end

def select : Pane
  @server.run!("select-pane", "-t", @pane_id)
  self
end

def clear_history : Pane
  @server.run!("clear-history", "-t", @pane_id)
  self
end

def kill : CommandResult
  @server.run!("kill-pane", "-t", @pane_id)
end
