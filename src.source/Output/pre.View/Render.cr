# Render the selected input as a fixed header, scrollable viewport, and footer.
def render(io : IO = STDOUT, height : Int32? = nil) : Nil
  @mutex.synchronize do
    screen_height = height || terminal_height
    screen_height = 1 if screen_height < 1

    unless selected = @selected_sequence
      write_frame(io, ["No inputs yet."], screen_height)
      next
    end

    unless command = @inputs[selected]?
      write_frame(io, ["Waiting for input ##{selected}..."], screen_height)
      next
    end

    render_selected(io, selected, command, screen_height)
  end
end

include Private
