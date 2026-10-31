@inputs = {} of UInt64 => String
@outputs = {} of UInt64 => String
@clean_outputs = {} of UInt64 => String
@statuses = {} of UInt64 => Int32
@selected_sequence : UInt64?
@raw_view = false
@mutex = Sync::Mutex.new

def initialize
  @selected_sequence = nil
end

# Switch the completed-command display between PTY transcript and extracted output.
def toggle_view : Bool
  @mutex.synchronize do
    @raw_view = !@raw_view
  end
end

include Update
include Render
