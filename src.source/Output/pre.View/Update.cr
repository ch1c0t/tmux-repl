# Apply one event from the session event stream to the displayed view.
def update(event : JSON::Any) : Nil
  @mutex.synchronize do
    sequence = event["sequence"].as_i64.to_u64

    case event["type"].as_s
    when "input"
      @scroll_offset = 0 if @selected_sequence != sequence
      @inputs[sequence] = event["command"].as_s
      @selected_sequence = sequence
    when "select"
      if @inputs.has_key?(sequence) && @selected_sequence != sequence
        @selected_sequence = sequence
        @scroll_offset = 0
      end
    when "output"
      chunk = event["chunk"].as_s
      previous = @outputs.fetch(sequence, "")
      updated = previous + chunk
      if sequence == @selected_sequence && @scroll_offset > 0 && !@statuses.has_key?(sequence)
        @scroll_offset += output_lines(updated).size - output_lines(previous).size
      end
      @outputs[sequence] = updated
    when "complete"
      @statuses[sequence] = event["status"].as_i64.to_i32
      if clean_output = event.as_h["clean_output"]?
        @clean_outputs[sequence] = clean_output.as_s
      end
    when "toggle_view"
      @raw_view = !@raw_view
    end
  end
end
