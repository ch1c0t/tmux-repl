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
