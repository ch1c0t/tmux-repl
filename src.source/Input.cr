class Reader < Reply::Reader
  @ready_path : String
  @keyboard : TmuxREPL::Keyboard::Dispatcher

  def initialize(
    @ready_path : String,
    @keyboard : TmuxREPL::Keyboard::Dispatcher
  )
    super()
  end

  # Queue every character; mapped shortcuts are consumed asynchronously.
  private def on_char(char : Char) : Nil
    super unless @keyboard.enqueue(char)
  end

  # Reply may return a batch of characters when several arrive in one read.
  private def on_string(string : String) : Nil
    editable = String.build do |io|
      string.each_char do |char|
        io << char unless @keyboard.enqueue(char)
      end
    end
    super(editable) unless editable.empty?
  end

  def prompt(io : IO, line_number : Int32, color : Bool)
    super(io, line_number, color)
    File.write(@ready_path, Process.pid.to_s) unless File.exists?(@ready_path)
  end
end
