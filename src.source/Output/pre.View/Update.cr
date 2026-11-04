# Apply one event from the session event stream to the displayed view.
def update(event : JSON::Any) : Nil
  @mutex.synchronize do
    sequence = event["sequence"].as_i64.to_u64

    case event["type"].as_s
    when "input"
      @list_scroll_offset += 1 if @list_view && @list_scroll_offset > 0
      @scroll_offset = 0 if @selected_sequence != sequence
      @horizontal_offset = 0 if @selected_sequence != sequence
      @inputs[sequence] = event["command"].as_s
      @selected_sequence = sequence
    when "select"
      if @inputs.has_key?(sequence) && @selected_sequence != sequence
        @selected_sequence = sequence
        @scroll_offset = 0
        @horizontal_offset = 0
      end
    when "output"
      chunk = event["chunk"].as_s
      previous = @outputs.fetch(sequence, "")
      updated = previous + chunk
      if sequence == @selected_sequence && @scroll_offset > 0 && !@statuses.has_key?(sequence)
        @scroll_offset += viewport_row_count(updated, @render_width) - viewport_row_count(previous, @render_width)
      end
      @outputs[sequence] = updated
    when "complete"
      @statuses[sequence] = event["status"].as_i64.to_i32
      if clean_output = event.as_h["clean_output"]?
        @clean_outputs[sequence] = clean_output.as_s
      end
    when "toggle_view"
      @raw_view = !@raw_view
    when "toggle_wrap"
      @wrap_lines = !@wrap_lines
      @horizontal_offset = 0
      @scroll_offset = 0
    when "toggle_list_view"
      @list_view = !@list_view
      @list_scroll_offset = 0
    when "scroll"
      if action = scroll_action(event["action"].as_s)
        scroll_current_view_locked(action)
      end
    end
  end
end
