getter session_name : String

@zoom_return_pane_id : String?

def initialize(@session_name : String)
  @state = TmuxREPL::State.open(@session_name)
  @zoom_return_pane_id = nil
end

include Helpers
include Consume
include Keyboard
include Run
