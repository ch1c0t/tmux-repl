getter name : String

def initialize(@name : String)
  raise ArgumentError.new("Invalid tmux session name") unless @name.matches?(/\A[a-zA-Z0-9_-]+\z/)
end

include Start
include Stop
include Helpers
