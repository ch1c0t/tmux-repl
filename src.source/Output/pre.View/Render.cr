# Draw the selected command, streaming transcript, or completed output.
def render(io : IO = STDOUT) : Nil
  @mutex.synchronize do
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

    io.puts "INPUT ##{selected} [#{mode_label}; Ctrl+G toggles view]"
    io.puts command
    io.puts "─" * 40

    displayed_output = if show_raw
      @outputs[selected]?
    else
      clean_output
    end

    if output = displayed_output
      io.print output
      io.puts unless output.ends_with?("\n") || output.empty?
    elsif !completed
      io.puts "(running...)"
    end

    if status = @statuses[selected]?
      io.puts "[exit status: #{status}]"
    end
    io.flush
  end
end
