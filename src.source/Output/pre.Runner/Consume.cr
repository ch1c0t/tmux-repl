private def handle_message(
  message : AMQP::Client::DeliverMessage,
  view : View
) : Nil
  begin
    data = JSON.parse(message.body_io.to_s)
    sequence = data["sequence"].as_i64.to_u64
    event_type = data["type"].as_s
    event_received_at = Time.instant if TmuxREPL.trace_timing_enabled?

    if event_type == "toggle_output_zoom"
      toggle_output_zoom(view, data)
    elsif event_type == "yank_output"
      yank_output(view)
    else
      view.update(data)

      render_started_at = Time.instant if TmuxREPL.trace_timing_enabled?
      view.render
      if render_started = render_started_at
        TmuxREPL.trace_timing(
          @session_name, "output", "event_rendered", render_started,
          "type=#{event_type} sequence=#{sequence}"
        )
      end
    end
    if event_started = event_received_at
      TmuxREPL.trace_timing(
        @session_name, "output", "event_handled", event_started,
        "type=#{event_type} sequence=#{sequence}"
      )
    end
    message.ack
  rescue ex
    STDERR.puts "tmux.repl.output: invalid event: #{ex.message}"
    begin
      message.reject(requeue: false)
    rescue
    end
  end
end


# Copy the complete selected output to both X11 selections.
private def yank_output(view : View) : Nil
  unless output = view.current_output
    STDERR.puts "tmux.repl.output: there is no current output to yank"
    return
  end

  X11Clipboard.new.copy(output)
  STDERR.puts "tmux.repl.output: current output copied to X11 clipboard and primary selection"
rescue ex
  STDERR.puts "tmux.repl.output: failed to yank current output: #{ex.message}"
end

# Alt+Z always zooms the Output pane. Remember the pane that requested the
# zoom so the second Alt+Z restores focus after removing the zoom.
private def toggle_output_zoom(view : View, data : JSON::Any) : Nil
  pane = Tmux::Pane.from_env
  zoomed = pane.display_message("\#{window_zoomed_flag}") == "1"

  if zoomed
    pane.run!("resize-pane", "-Z", "-t", pane.pane_id)
    if return_pane_id = @zoom_return_pane_id
      pane.run!("select-pane", "-t", return_pane_id)
    end
    @zoom_return_pane_id = nil
  else
    @zoom_return_pane_id = data["requesting_pane"]?.try(&.as_s)
    pane.select
    pane.run!("resize-pane", "-Z", "-t", pane.pane_id)
  end

  view.render
end
