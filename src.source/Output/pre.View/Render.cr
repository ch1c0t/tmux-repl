# Draw a fixed header and status around a scrollable output viewport.
def render(io : IO = STDOUT, height : Int32? = nil) : Nil
  @mutex.synchronize do
    screen_height = height || terminal_height
    screen_height = 1 if screen_height < 1

    unless selected = @selected_sequence
      render_frame(io, ["No inputs yet."], screen_height)
      next
    end

    command = @inputs[selected]?
    unless command
      render_frame(io, ["Waiting for input ##{selected}..."], screen_height)
      next
    end

    completed = @statuses.has_key?(selected)
    clean_output = @clean_outputs[selected]?
    show_raw = !completed || @raw_view || clean_output.nil?
    mode_label = if completed
      show_raw ? "RAW" : "STRIPPED"
    else
      "STREAMING"
    end

    toggle_key = TmuxREPL::Keyboard.label_for(TmuxREPL::Keyboard::Action::ToggleOutputView)
    header = [
      "INPUT ##{selected} [#{mode_label}; #{toggle_key} toggles view]",
      *output_lines(command),
      "─" * 40,
    ]

    displayed_output = if show_raw
      @outputs[selected]?
    else
      clean_output
    end

    body = if output = displayed_output
      output_lines(output)
    elsif !completed
      ["(running...)"]
    else
      [] of String
    end

    footer = ["[Up/Down: scroll; PageUp/PageDown: page]"]
    footer << "[exit status: #{@statuses[selected]}]" if status = @statuses[selected]?

    # Keep the footer visible even when a long command leaves little room for output.
    footer = footer.last(screen_height)
    header_limit = screen_height - footer.size - 1
    header = header.first(header_limit) if header.size > header_limit
    @body_height = screen_height - header.size - footer.size
    @scrollable_lines = body.size

    max_offset = @scrollable_lines - @body_height
    max_offset = 0 if max_offset < 0
    @scroll_offset = 0 if @scroll_offset < 0
    @scroll_offset = max_offset if @scroll_offset > max_offset

    visible_end = @scrollable_lines - @scroll_offset
    visible_start = visible_end - @body_height
    visible_start = 0 if visible_start < 0

    frame = header.dup
    index = visible_start
    while index < visible_end
      frame << body[index]
      index += 1
    end
    frame.concat(footer)
    render_frame(io, frame, screen_height)
  end
end

# Rewrite each row in place. Clearing to end-of-line removes remnants of longer
# previous rows without blanking the whole pane between frames.
private def render_frame(io : IO, lines : Array(String), height : Int32) : Nil
  output = String.build do |buffer|
    height.times do |index|
      line = lines[index]? || ""
      buffer << "\e[" << (index + 1) << ";1H"
      buffer << line
      buffer << "\e[0K"
    end
  end
  io.print output
  io.flush
end
