@ready_path : String
@keyboard : TmuxREPL::Keyboard::Dispatcher
@keyboard_io : TmuxREPL::Keyboard::InputIO(IO::FileDescriptor)
@on_previous : Proc(Nil)?
@on_next : Proc(Nil)?

def initialize(
  @ready_path : String,
  @keyboard : TmuxREPL::Keyboard::Dispatcher,
  @on_previous : Proc(Nil)? = nil,
  @on_next : Proc(Nil)? = nil
)
  @keyboard_io = TmuxREPL::Keyboard::InputIO.new(STDIN, @keyboard)
  super()
end

include ReadNext

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
