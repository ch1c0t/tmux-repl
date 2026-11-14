@ready_path : String
@keyboard : TmuxREPL::Keyboard::Dispatcher
@keyboard_io : TmuxREPL::Keyboard::InputIO(IO::FileDescriptor)
@on_previous : Proc(Nil)?
@on_next : Proc(Nil)?
@command_completer : CommandCompleter

def initialize(
  @ready_path : String,
  @keyboard : TmuxREPL::Keyboard::Dispatcher,
  @on_previous : Proc(Nil)? = nil,
  @on_next : Proc(Nil)? = nil
)
  @keyboard_io = TmuxREPL::Keyboard::InputIO.new(STDIN, @keyboard)
  @command_completer = CommandCompleter.new
  super()
end

include ReadNext

def auto_complete(current_word : String, expression_before : String) : {String, Array(String)}
  return {"", [] of String} unless expression_before.strip.empty?

  {"Shell commands", @command_completer.complete(current_word)}
end

# Open Reply's suggestion list as soon as the first command character is typed.
# The editor text is left untouched; Tab/Shift+Tab can accept or cycle suggestions.
private def on_char(char : Char) : Nil
  super

  if command_position?
    unless @auto_completion.open?
      compute_completions
      @auto_completion.open unless @auto_completion.entries.empty?
    end
  else
    @auto_completion.close if @auto_completion.open?
  end
end

private def command_position? : Bool
  word_begin, _word_end = @editor.current_word_begin_end
  @editor.expression_before_cursor(x: word_begin).strip.empty?
end

private def on_ctrl_up(& : String ->) : Nil
  binding = @keyboard_io.take_navigation_binding(TmuxREPL::Keyboard::Action::SelectPrevious)
  if callback = @on_previous
    callback.call
    @keyboard.enqueue(
      binding || TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Up").not_nil!
    )
  else
    @editor.scroll_down
  end
end

private def on_ctrl_down(& : String ->) : Nil
  binding = @keyboard_io.take_navigation_binding(TmuxREPL::Keyboard::Action::SelectNext)
  if callback = @on_next
    callback.call
    @keyboard.enqueue(
      binding || TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Down").not_nil!
    )
  else
    @editor.scroll_up
  end
end

def prompt(io : IO, line_number : Int32, color : Bool)
  super(io, line_number, color)
  File.write(@ready_path, Process.pid.to_s) unless File.exists?(@ready_path)
end
