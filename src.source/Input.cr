class Reader < Reply::Reader
  @ready_path : String

  def initialize(
    @ready_path : String,
    @session_name : String,
    @events : AMQP::Client::Queue
  )
    super()
  end

  # Ctrl+G is shared with the output pane and never enters the command buffer.
  private def on_char(char : Char) : Nil
    if char == '\u0007'
      TmuxREPL.publish_event(@events, "toggle_view", @session_name, 0_u64)
    else
      super
    end
  end

  def prompt(io : IO, line_number : Int32, color : Bool)
    super(io, line_number, color)
    File.write(@ready_path, Process.pid.to_s) unless File.exists?(@ready_path)
  end
end
