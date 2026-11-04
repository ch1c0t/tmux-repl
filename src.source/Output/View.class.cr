@inputs = {} of UInt64 => String
@outputs = {} of UInt64 => String
@clean_outputs = {} of UInt64 => String
@statuses = {} of UInt64 => Int32
@selected_sequence : UInt64?
@raw_view = false
@list_view = false
@wrap_lines = true
@horizontal_offset = 0
@render_width = 79
@list_scroll_offset = 0
@list_body_height = 1
@list_scrollable_lines = 0
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

# Switch between wrapped logical lines and one-row-per-line horizontal inspection.
def toggle_wrap : Bool
  @mutex.synchronize do
    @wrap_lines = !@wrap_lines
    @horizontal_offset = 0
    @scroll_offset = 0
    @wrap_lines
  end
end

def wrap_lines? : Bool
  @mutex.synchronize { @wrap_lines }
end

# Move the output viewport vertically or horizontally.
def scroll(action : TmuxREPL::Keyboard::Action) : Bool
  @mutex.synchronize { scroll_current_view_locked(action) }
end

private def scroll_current_view_locked(action : TmuxREPL::Keyboard::Action) : Bool
  @list_view ? scroll_list_locked(action) : scroll_locked(action)
end

private def scroll_list_locked(action : TmuxREPL::Keyboard::Action) : Bool
  previous_offset = @list_scroll_offset
  page_step = @list_body_height - 1
  page_step = 1 if page_step < 1

  case action
  when TmuxREPL::Keyboard::Action::ScrollUp
    @list_scroll_offset += 1
  when TmuxREPL::Keyboard::Action::ScrollDown
    @list_scroll_offset -= 1
  when TmuxREPL::Keyboard::Action::ScrollPageUp
    @list_scroll_offset += page_step
  when TmuxREPL::Keyboard::Action::ScrollPageDown
    @list_scroll_offset -= page_step
  end

  max_offset = @list_scrollable_lines - @list_body_height
  max_offset = 0 if max_offset < 0
  @list_scroll_offset = 0 if @list_scroll_offset < 0
  @list_scroll_offset = max_offset if @list_scroll_offset > max_offset

  @list_scroll_offset != previous_offset
end

private def scroll_locked(action : TmuxREPL::Keyboard::Action) : Bool
  previous_offset = @scroll_offset
  previous_horizontal_offset = @horizontal_offset
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
  when TmuxREPL::Keyboard::Action::ScrollHorizontalLeft
    @horizontal_offset -= 1 if !@wrap_lines && @horizontal_offset > 0
  when TmuxREPL::Keyboard::Action::ScrollHorizontalRight
    @horizontal_offset += 1 if !@wrap_lines && @horizontal_offset < maximum_horizontal_offset
  when TmuxREPL::Keyboard::Action::ScrollHorizontalStart
    @horizontal_offset = 0 unless @wrap_lines
  when TmuxREPL::Keyboard::Action::ScrollHorizontalEnd
    @horizontal_offset = maximum_horizontal_offset unless @wrap_lines
  end

  max_offset = @scrollable_lines - @body_height
  max_offset = 0 if max_offset < 0
  @scroll_offset = 0 if @scroll_offset < 0
  @scroll_offset = max_offset if @scroll_offset > max_offset

  @horizontal_offset = 0 if @wrap_lines
  @horizontal_offset = maximum_horizontal_offset if @horizontal_offset > maximum_horizontal_offset

  @scroll_offset != previous_offset || @horizontal_offset != previous_horizontal_offset
end

private def maximum_horizontal_offset : Int32
  return 0 if @wrap_lines
  return 0 unless sequence = @selected_sequence

  completed = @statuses.has_key?(sequence)
  displayed_output, _label = displayed_output_for(sequence, completed)
  return 0 unless output = displayed_output

  widest_line = output_lines(output).max_of? { |line| display_width(line) } || 0
  visible_width = @render_width - 1
  visible_width = 0 if visible_width < 0
  offset = widest_line - visible_width
  offset > 0 ? offset : 0
end

private def scroll_action(name : String) : TmuxREPL::Keyboard::Action?
  case name
  when "ScrollUp"                   then TmuxREPL::Keyboard::Action::ScrollUp
  when "ScrollDown"                 then TmuxREPL::Keyboard::Action::ScrollDown
  when "ScrollPageUp"               then TmuxREPL::Keyboard::Action::ScrollPageUp
  when "ScrollPageDown"             then TmuxREPL::Keyboard::Action::ScrollPageDown
  when "ScrollHorizontalLeft"       then TmuxREPL::Keyboard::Action::ScrollHorizontalLeft
  when "ScrollHorizontalRight"      then TmuxREPL::Keyboard::Action::ScrollHorizontalRight
  when "ScrollHorizontalStart"      then TmuxREPL::Keyboard::Action::ScrollHorizontalStart
  when "ScrollHorizontalEnd"        then TmuxREPL::Keyboard::Action::ScrollHorizontalEnd
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
