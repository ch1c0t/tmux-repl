@inputs = {} of UInt64 => String
@outputs = {} of UInt64 => String
@statuses = {} of UInt64 => Int32
@selected_sequence : UInt64?

def initialize
  @selected_sequence = nil
end

include Update
include Render
