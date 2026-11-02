# Reply may batch ordinary text with the Enter byte; keep Enter parseable.
def read_next(from io : IO = STDIN) : String?
  super(from: @keyboard_io)
end

# Enqueue all ordinary characters; bound shortcuts are consumed by the dispatcher.
private def on_char(char : Char) : Nil
  super unless TmuxREPL::Keyboard.binding_for(char)
end

# Reply may return a batch of characters when several arrive in one read.
private def on_string(string : String) : Nil
  editable = String.build do |io|
    string.each_char do |char|
      io << char unless TmuxREPL::Keyboard.binding_for(char)
    end
  end
  super(editable) unless editable.empty?
end
