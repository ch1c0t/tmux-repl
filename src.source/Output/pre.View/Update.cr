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
