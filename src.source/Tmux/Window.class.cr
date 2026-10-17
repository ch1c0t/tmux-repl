getter server : Server
getter session_id : String
getter window_id : String

def initialize(@server : Server, @session_id : String, @window_id : String)
end

def self.from_env(binary : String = "tmux") : Window
  Pane.from_env(binary).window
end

include Private
include Public
