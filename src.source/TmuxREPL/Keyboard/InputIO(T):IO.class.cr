@source_buffer = Bytes.new(8192)
@read_buffer = Bytes.new(8192 * 3)
@pending_source = [] of UInt8
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

  refill if @source_offset >= @source_size && !@eof
  return 0 if @source_offset >= @source_size

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

# Reply reports native Ctrl arrows and translated Alt+K/J through its existing
# callbacks. Preserve the original binding so the dispatcher can trace the key.
def take_navigation_binding(action : Action) : SequenceBinding?
  return if @navigation_bindings.empty?

  binding = @navigation_bindings.first
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

# Read until a complete input sequence or ordinary characters are available.
# A trailing escape-sequence prefix is retained for the next OS read.
private def refill : Nil
  loop do
    raw_size = @source.read(@source_buffer)
    raw_size.times { |index| @pending_source << @source_buffer[index] }

    @source_offset = 0
    @eof = raw_size == 0
    @source_size = translate_navigation_sequences(@eof)
    break if @source_size > 0 || @eof
  end
end

# Consume Alt scrolling locally in the input frontend, while translating the
# existing Alt+K/J aliases into the Ctrl arrows understood by Reply 0.4.
private def translate_navigation_sequences(eof : Bool) : Int32
  input_offset = 0
  output_size = 0
  limit = @pending_source.size

  while input_offset < limit
    if matches?(@pending_source, input_offset, limit, "\f")
      @keyboard.try &.enqueue('\u000c')
      input_offset += 1
    elsif matches?(@pending_source, input_offset, limit, "\u0017")
      @keyboard.try &.enqueue('\u0017')
      input_offset += 1
    elsif sequence = input_scroll_sequence(input_offset, limit)
      binding, input_size = sequence
      @keyboard.try &.enqueue(binding)
      input_offset += input_size
    elsif sequence = alt_navigation_sequence(input_offset, limit)
      binding, input_size = sequence
      @navigation_bindings << binding

      translated = binding.action == Action::SelectPrevious ? "\e[1;5A" : "\e[1;5B"
      output_size += append_sequence(translated, output_size)
      input_offset += input_size
    elsif binding = control_navigation_binding(input_offset, limit)
      @navigation_bindings << binding
      translated = binding.action == Action::SelectPrevious ? "\e[1;5A" : "\e[1;5B"
      output_size += append_sequence(translated, output_size)
      input_offset += translated.bytesize
    elsif !eof && incomplete_sequence_prefix?(input_offset, limit)
      break
    else
      @read_buffer[output_size] = @pending_source[input_offset]
      output_size += 1
      input_offset += 1
    end
  end

  @pending_source.shift(input_offset) if input_offset > 0
  output_size
end

private def input_scroll_sequence(offset : Int32, limit : Int32) : Tuple(SequenceBinding, Int32)?
  TmuxREPL::Keyboard::INPUT_SCROLL_SEQUENCES.each do |sequence, label|
    if matches?(@pending_source, offset, limit, sequence)
      return {
        TmuxREPL::Keyboard.sequence_binding_for(label).not_nil!,
        sequence.bytesize,
      }
    end
  end
end

private def alt_navigation_sequence(offset : Int32, limit : Int32) : Tuple(SequenceBinding, Int32)?
  if matches?(@pending_source, offset, limit, "\ek")
    {TmuxREPL::Keyboard.sequence_binding_for("Alt+K").not_nil!, 2}
  elsif matches?(@pending_source, offset, limit, "\ej")
    {TmuxREPL::Keyboard.sequence_binding_for("Alt+J").not_nil!, 2}
  elsif matches?(@pending_source, offset, limit, "\e[107;3u")
    {TmuxREPL::Keyboard.sequence_binding_for("Alt+K").not_nil!, 8}
  elsif matches?(@pending_source, offset, limit, "\e[106;3u")
    {TmuxREPL::Keyboard.sequence_binding_for("Alt+J").not_nil!, 8}
  end
end

private def control_navigation_binding(offset : Int32, limit : Int32) : SequenceBinding?
  if matches?(@pending_source, offset, limit, "\e[1;5A")
    TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Up")
  elsif matches?(@pending_source, offset, limit, "\e[1;5B")
    TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Down")
  end
end

private def incomplete_sequence_prefix?(offset : Int32, limit : Int32) : Bool
  suffix = String.build do |io|
    index = offset
    while index < limit
      io.write_byte(@pending_source[index])
      index += 1
    end
  end

  TmuxREPL::Keyboard::INPUT_SEQUENCE_STRINGS.any? { |sequence| sequence.starts_with?(suffix) }
end

private def append_sequence(sequence : String, offset : Int32) : Int32
  bytes = sequence.to_slice
  @read_buffer[offset, bytes.size].copy_from(bytes)
  bytes.size
end

private def matches?(
  buffer : Array(UInt8),
  offset : Int32,
  limit : Int32,
  sequence : String
) : Bool
  bytes = sequence.to_slice
  return false if offset + bytes.size > limit

  bytes.size.times do |index|
    return false unless buffer[offset + index] == bytes[index]
  end
  true
end

private def matches?(
  buffer : Bytes,
  offset : Int32,
  limit : Int32,
  sequence : String
) : Bool
  bytes = sequence.to_slice
  return false if offset + bytes.size > limit

  bytes.size.times do |index|
    return false unless buffer[offset + index] == bytes[index]
  end
  true
end

# Keep Enter and each Ctrl navigation sequence in a separate read so Reply can
# parse them even when ordinary text or another key arrived in the same OS read.
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
