@source_buffer = Bytes.new(8192)
@source_size = 0
@source_offset = 0
@eof = false

def initialize(@source : T)
end

def read(slice : Bytes) : Int32
  return 0 if slice.empty?

  refill if @source_offset >= @source_size
  return 0 if @eof

  available = @source_size - @source_offset
  count = bytes_before_carriage_return(available)
  count = Math.min(count, slice.size)

  slice[0, count].copy_from(@source_buffer[@source_offset, count])
  @source_offset += count
  count
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
  @source_size = @source.read(@source_buffer)
  @source_offset = 0
  @eof = @source_size == 0
end

# Keep Enter separate from a batched text read so Reply can submit the line.
private def bytes_before_carriage_return(available : Int32) : Int32
  available.times do |index|
    return index == 0 ? 1 : index if @source_buffer[@source_offset + index] == '\r'.ord
  end
  available
end
