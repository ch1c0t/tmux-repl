getter entries : Array(Tuple(UInt64, String))
getter selected_sequence : UInt64?

@sequence = 0_u64
@entries = [] of Tuple(UInt64, String)
@selected_sequence : UInt64?

def initialize
  @selected_sequence = nil
end

def add(expression : String) : UInt64
  @sequence &+= 1_u64
  @entries << {@sequence, expression}
  @selected_sequence = @sequence
  @sequence
end

def includes?(sequence : UInt64) : Bool
  @entries.any? { |entry| entry[0] == sequence }
end

def select(sequence : UInt64) : Bool
  return false unless includes?(sequence)

  @selected_sequence = sequence
  true
end

def previous_sequence : UInt64?
  adjacent_sequence(-1)
end

def next_sequence : UInt64?
  adjacent_sequence(1)
end

private def adjacent_sequence(direction : Int32) : UInt64?
  selected = @selected_sequence
  return unless selected

  index = @entries.index { |entry| entry[0] == selected }
  return unless index

  target_index = index + direction
  return if target_index < 0 || target_index >= @entries.size

  @entries[target_index][0]
end
