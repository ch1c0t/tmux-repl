class OutputView
  @inputs = {} of UInt64 => String
  @outputs = {} of UInt64 => String
  @statuses = {} of UInt64 => Int32
  @selected_sequence : UInt64?

  def initialize
    @selected_sequence = nil
  end

  # Apply one event from the session event stream to the displayed view.
  def update(event : JSON::Any) : Nil
    sequence = event["sequence"].as_i64.to_u64

    case event["type"].as_s
    when "input"
      @inputs[sequence] = event["command"].as_s
      @selected_sequence = sequence
    when "select"
      @selected_sequence = sequence if @inputs.has_key?(sequence)
    when "output"
      chunk = event["chunk"].as_s
      @outputs[sequence] = @outputs.fetch(sequence, "") + chunk
    when "complete"
      @statuses[sequence] = event["status"].as_i64.to_i32
    end
  end

  # Draw the currently selected input and its output.
  def render(io : IO = STDOUT) : Nil
    io.print "\e[H\e[2J"
    io.flush

    unless selected = @selected_sequence
      io.puts "No inputs yet."
      io.flush
      return
    end

    command = @inputs[selected]?
    unless command
      io.puts "Waiting for input ##{selected}..."
      io.flush
      return
    end

    io.puts "INPUT ##{selected}"
    io.puts command
    io.puts "─" * 40

    if output = @outputs[selected]?
      io.print output
      io.puts unless output.ends_with?("\n") || output.empty?
    else
      io.puts "(running...)"
    end

    if status = @statuses[selected]?
      io.puts "[exit status: #{status}]"
    end
    io.flush
  end
end
