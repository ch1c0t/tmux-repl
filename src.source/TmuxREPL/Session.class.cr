getter name : String

getter? in_tmux : Bool
getter output_pane : File?

def initialize(@name : String)
  raise ArgumentError.new("Invalid tmux session name") unless @name.matches?(/\A[a-zA-Z0-9_-]+\z/)

  # Check if the process is running inside an active Tmux environment
  @in_tmux = ENV.has_key?("TMUX")
  @output_pane = nil
end

include Start
include Stop
include Helpers
