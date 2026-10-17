getter server : Server
getter session_id : String

def initialize(@server : Server, @session_id : String)
end

def self.from_env(binary : String = "tmux") : Session
  Pane.from_env(binary).session
end

include Private
include Public
