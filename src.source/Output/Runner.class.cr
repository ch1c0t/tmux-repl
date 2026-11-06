getter session_name : String

def initialize(@session_name : String)
  @state = TmuxREPL::State.open(@session_name)
end

include Helpers
include Consume
include Keyboard
include Run
