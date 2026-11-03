@source_buffer = Bytes.new(8192)
@read_buffer = Bytes.new(8192 * 3)
@source_size = 0
@source_offset = 0
@navigation_bindings = [] of SequenceBinding
@eof = false

def initialize(
  @source : T,
  @keyboard : Dispatcher? = nil
)
end

def read(slice : Bytes) : Int32
  return 0 if slice.empty?

  refill if @source_offset >= @source_size
  return 0 if @eof

  available = @source_size - @source_offset
  count = bytes_before_line_ending(available)
  count = Math.min(count, slice.size)

  slice[0, count].copy_from(@read_buffer[@source_offset, count])
  @source_offset += count
  if keyboard = @keyboard
    String.new(slice[0, count]).each_char { |char| keyboard.enqueue(char) }
  end
  count
end

# Reply reports both native Ctrl arrows and translated Alt aliases through its
# existing Ctrl+Up/Down callbacks. Keep the original binding for diagnostics.
def take_navigation_binding(action : Action) : SequenceBinding?
  return unless binding = @navigation_bindings.first?
  return unless binding.action == action

  @navigation_bindings.shift
end

def write(slice : Bytes) : Nil
  raise IO::Error.new("Keyboard input IO is read-only")
end

def tty? : Bool
  {% if T.has_method?(:tty?) %}
    @source.tty?
  {% else %}
    false
  {% end %}
end

def raw(& : self -> _)
  {% if T.has_method?(:raw) %}
    if @source.tty?
      @source.raw { yield self }
    else
      yield self
    end
  {% else %}
    yield self
  {% end %}
end

private def refill : Nil
  raw_size = @source.read(@source_buffer)
  @source_offset = 0
  @source_size = translate_navigation_sequences(raw_size)
  @eof = raw_size == 0
end

# Translate Alt+K/J into the Ctrl+Up/Down sequences understood by Reply 0.4.
# Both ESC-prefixed terminal input and Kitty CSI-u input are accepted.
private def translate_navigation_sequences(raw_size : Int32) : Int32
  input_offset = 0
  output_size = 0

  while input_offset < raw_size
    if sequence = alt_navigation_sequence(input_offset, raw_size)
      binding, input_size = sequence
      @navigation_bindings << binding

      translated = binding.action == Action::SelectPrevious ? "\e[1;5A" : "\e[1;5B"
      output_size += append_sequence(translated, output_size)
      input_offset += input_size
    elsif binding = control_navigation_binding(input_offset, raw_size)
      @navigation_bindings << binding
      sequence_size = "\e[1;5A".bytesize
      @read_buffer[output_size, sequence_size].copy_from(@source_buffer[input_offset, sequence_size])
      output_size += sequence_size
      input_offset += sequence_size
    else
      @read_buffer[output_size] = @source_buffer[input_offset]
      output_size += 1
      input_offset += 1
    end
  end

  output_size
end

private def alt_navigation_sequence(offset : Int32, limit : Int32) : Tuple(SequenceBinding, Int32)?
  if matches?(@source_buffer, offset, limit, "\ek")
    {TmuxREPL::Keyboard.sequence_binding_for("Alt+K").not_nil!, 2}
  elsif matches?(@source_buffer, offset, limit, "\ej")
    {TmuxREPL::Keyboard.sequence_binding_for("Alt+J").not_nil!, 2}
  elsif matches?(@source_buffer, offset, limit, "\e[107;3u")
    {TmuxREPL::Keyboard.sequence_binding_for("Alt+K").not_nil!, 8}
  elsif matches?(@source_buffer, offset, limit, "\e[106;3u")
    {TmuxREPL::Keyboard.sequence_binding_for("Alt+J").not_nil!, 8}
  end
end

private def control_navigation_binding(offset : Int32, limit : Int32) : SequenceBinding?
  if matches?(@source_buffer, offset, limit, "\e[1;5A")
    TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Up")
  elsif matches?(@source_buffer, offset, limit, "\e[1;5B")
    TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Down")
  end
end

private def append_sequence(sequence : String, offset : Int32) : Int32
  bytes = sequence.to_slice
  @read_buffer[offset, bytes.size].copy_from(bytes)
  bytes.size
end

private def matches?(buffer : Bytes, offset : Int32, limit : Int32, sequence : String) : Bool
  bytes = sequence.to_slice
  return false if offset + bytes.size > limit

  bytes.size.times do |index|
    return false unless buffer[offset + index] == bytes[index]
  end
  true
end

# Keep Enter and each navigation sequence in a separate read so Reply sees them
# even when ordinary text or another key arrived in the same OS read.
private def bytes_before_line_ending(available : Int32) : Int32
  available.times do |index|
    offset = @source_offset + index
    byte = @read_buffer[offset]

    return index == 0 ? 1 : index if byte == '\r'.ord
    return index == 0 ? 1 : index if byte == '\n'.ord && index == available - 1

    if byte == '\e'.ord
      if sequence_size = navigation_sequence_size(offset, @source_size)
        return index == 0 ? sequence_size : index
      end
    end
  end
  available
end

private def navigation_sequence_size(offset : Int32, limit : Int32) : Int32?
  sequence = "\e[1;5A"
  return sequence.bytesize if matches?(@read_buffer, offset, limit, sequence)

  sequence = "\e[1;5B"
  return sequence.bytesize if matches?(@read_buffer, offset, limit, sequence)
end
