private def watch_keyboard(
  dispatcher : TmuxREPL::Keyboard::Dispatcher,
  terminal_mode : TmuxREPL::TerminalMode
) : Nil
  return unless terminal_mode.enable

  spawn do
    pending = [] of UInt8
    buffer = Bytes.new(128)

    begin
      loop do
        count = STDIN.read(buffer)
        break if count == 0

        count.times { |index| pending << buffer[index] }
        dispatch_keyboard_input(pending, dispatcher)
      end
      dispatch_keyboard_input(pending, dispatcher, flush: true)
    rescue IO::Error
      # The pane may close while the keyboard reader is waiting.
    ensure
      terminal_mode.restore
    end
  end
end

# Keep incomplete escape-sequence prefixes until the next read. This handles
# arrow and page-key sequences even when the PTY splits them across reads.
private def dispatch_keyboard_input(
  pending : Array(UInt8),
  dispatcher : TmuxREPL::Keyboard::Dispatcher,
  flush : Bool = false
) : Nil
  until pending.empty?
    input = String.build do |io|
      pending.each { |byte| io.write_byte(byte) }
    end

    if match = TmuxREPL::Keyboard.output_sequence_match(input)
      sequence, binding = match
      sequence.bytesize.times { pending.shift }
      dispatcher.enqueue(binding)
    elsif !flush && TmuxREPL::Keyboard.output_sequence_prefix?(input)
      break
    else
      dispatcher.enqueue(pending.shift.chr)
    end
  end
end
