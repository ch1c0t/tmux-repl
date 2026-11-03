@inputs = {} of UInt64 => String
@outputs = {} of UInt64 => String
@clean_outputs = {} of UInt64 => String
@statuses = {} of UInt64 => Int32
@selected_sequence : UInt64?
@raw_view = false
@scroll_offset = 0
@body_height = 1
@scrollable_lines = 0
@cached_terminal_height = 24
@terminal_height_checked_at : Time::Instant?
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

# Move the output viewport without moving the pinned command header or status.
def scroll(action : TmuxREPL::Keyboard::Action) : Bool
  @mutex.synchronize do
    previous_offset = @scroll_offset
    page_step = @body_height - 1
    page_step = 1 if page_step < 1

    case action
    when TmuxREPL::Keyboard::Action::ScrollUp
      @scroll_offset += 1
    when TmuxREPL::Keyboard::Action::ScrollDown
      @scroll_offset -= 1
    when TmuxREPL::Keyboard::Action::ScrollPageUp
      @scroll_offset += page_step
    when TmuxREPL::Keyboard::Action::ScrollPageDown
      @scroll_offset -= page_step
    end

    max_offset = @scrollable_lines - @body_height
    max_offset = 0 if max_offset < 0
    @scroll_offset = 0 if @scroll_offset < 0
    @scroll_offset = max_offset if @scroll_offset > max_offset

    @scroll_offset != previous_offset
  end
end

private def output_lines(text : String) : Array(String)
  normalized = text.gsub("\r\n", "\n").gsub("\r", "\n")
  return [] of String if normalized.empty?

  lines = normalized.split('\n', remove_empty: false)
  lines.pop if normalized.ends_with?('\n')
  lines
end

private def terminal_height : Int32
  if checked_at = @terminal_height_checked_at
    return @cached_terminal_height if Time.instant - checked_at < 250.milliseconds
  end

  @terminal_height_checked_at = Time.instant
  @cached_terminal_height = Tmux::Pane.from_env.height
rescue
  @cached_terminal_height = ENV["LINES"]?.try(&.to_i?) || 24
end

include Update
include Render
