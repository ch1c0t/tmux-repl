class Reader < Reply::Reader
  @ready_path : String

  def initialize(
    @ready_path : String,
    @session_name : String,
    @events : AMQP::Client::Queue
  )
    super()
  end

  # Dispatch shared keyboard actions without adding shortcuts to the command buffer.
  private def on_char(char : Char) : Nil
    case TmuxREPL::Keyboard.action_for(char)
    when TmuxREPL::Keyboard::Action::ToggleOutputView
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
