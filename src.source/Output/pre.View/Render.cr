# Draw a fixed header and status around a scrollable output viewport.
def render(io : IO = STDOUT, height : Int32? = nil) : Nil
  @mutex.synchronize do
    screen_height = height || terminal_height
    screen_height = 1 if screen_height < 1

    io.print "\e[H\e[2J"
    io.flush

    unless selected = @selected_sequence
      io.puts "No inputs yet."
      io.flush
      next
    end

    command = @inputs[selected]?
    unless command
      io.puts "Waiting for input ##{selected}..."
      io.flush
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

    @body_height = screen_height - header.size - footer.size
    @body_height = 1 if @body_height < 1
    @scrollable_lines = body.size

    max_offset = @scrollable_lines - @body_height
    max_offset = 0 if max_offset < 0
    @scroll_offset = 0 if @scroll_offset < 0
    @scroll_offset = max_offset if @scroll_offset > max_offset

    visible_end = @scrollable_lines - @scroll_offset
    visible_start = visible_end - @body_height
    visible_start = 0 if visible_start < 0

    header.each { |line| io.puts line }

    index = visible_start
    while index < visible_end
      io.puts body[index]
      index += 1
    end

    footer.each { |line| io.puts line }
    io.flush
  end
end
