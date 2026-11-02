@ready_path : String
@keyboard : TmuxREPL::Keyboard::Dispatcher
@keyboard_io : TmuxREPL::Keyboard::InputIO(IO::FileDescriptor)

def initialize(
  @ready_path : String,
  @keyboard : TmuxREPL::Keyboard::Dispatcher
)
  @keyboard_io = TmuxREPL::Keyboard::InputIO.new(STDIN, @keyboard)
  super()
end

include ReadNext

def prompt(io : IO, line_number : Int32, color : Bool)
  super(io, line_number, color)
  File.write(@ready_path, Process.pid.to_s) unless File.exists?(@ready_path)
end
