getter session_name : String

def initialize(@session_name : String)
end

include Helpers
include Consume
include Run
