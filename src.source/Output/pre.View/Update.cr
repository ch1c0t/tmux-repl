# Apply one event from the session event stream to the displayed view.
def update(event : JSON::Any) : Nil
  @mutex.synchronize do
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
      if clean_output = event.as_h["clean_output"]?
        @clean_outputs[sequence] = clean_output.as_s
      end
    when "toggle_view"
      @raw_view = !@raw_view
    end
  end
end
