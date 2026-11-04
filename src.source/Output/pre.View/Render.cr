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

# Assemble the four visible components for one selected input.
private def render_selected(
  io : IO,
  sequence : UInt64,
  command : String,
  screen_height : Int32
) : Nil
  completed = @statuses.has_key?(sequence)
  displayed_output, mode_label = displayed_output_for(sequence, completed)

  header = header_lines(sequence, command, mode_label)
  footer = footer_lines(sequence)

  header, footer, body_height = fit_sections(header, footer, screen_height)
  viewport = build_viewport(displayed_output, completed, body_height)
  footer[-1] = viewport.line_summary(completed)

  write_frame(io, compose_frame(header, viewport, footer), screen_height)
end

# Choose the transcript representation and its matching mode label.
private def displayed_output_for(sequence : UInt64, completed : Bool) : Tuple(String?, String)
  clean_output = @clean_outputs[sequence]?
  show_raw = !completed || @raw_view || clean_output.nil?

  mode_label = if completed
    show_raw ? "RAW" : "STRIPPED"
  else
    "STREAMING"
  end

  displayed_output = if show_raw
    @outputs[sequence]?
  else
    clean_output
  end

  {displayed_output, mode_label}
end

# The header is pinned while the output viewport scrolls.
private def header_lines(sequence : UInt64, command : String, mode_label : String) : Array(String)
  toggle_key = TmuxREPL::Keyboard.label_for(TmuxREPL::Keyboard::Action::ToggleOutputView)
  [
    "INPUT ##{sequence} [#{mode_label}; #{toggle_key} toggles view]",
    *output_lines(command),
    "─" * 40,
  ]
end

# Reserve the final footer row for the viewport's line-range summary.
private def footer_lines(sequence : UInt64) : Array(String)
  lines = ["[Up/Down: scroll; PageUp/PageDown: page]"]
  lines << "[exit status: #{@statuses[sequence]}]" if status = @statuses[sequence]?
  lines << ""
  lines
end

# Clip the fixed sections first so the viewport receives the remaining rows.
private def fit_sections(
  header : Array(String),
  footer : Array(String),
  height : Int32
) : Tuple(Array(String), Array(String), Int32)
  footer = footer.last(height)

  header_limit = height - footer.size - 1
  header_limit = 0 if header_limit < 0
  header = header.first(header_limit) if header.size > header_limit

  body_height = height - header.size - footer.size
  {header, footer, body_height}
end

# The viewport owns scrolling, visible-line selection, and logical line numbering.
private struct Viewport
  getter lines : Array(String)
  getter total_lines : Int32
  getter first_line : Int32?
  getter last_line : Int32?

  def initialize(
    @lines : Array(String),
    @total_lines : Int32,
    @first_line : Int32?,
    @last_line : Int32?
  )
  end

  def line_summary(completed : Bool) : String
    if @total_lines == 0
      completed ? "[0 output lines]" : "[0 output lines so far]"
    elsif first = @first_line
      last = @last_line.not_nil!
      progress = completed ? "" : " so far"
      "[Output lines #{first}–#{last} of #{@total_lines}#{progress}]"
    else
      "[0 of #{@total_lines} output lines visible]"
    end
  end
end

private def build_viewport(
  displayed_output : String?,
  completed : Bool,
  height : Int32
) : Viewport
  body = if output = displayed_output
    output_lines(output)
  elsif !completed
    ["(running...)"]
  else
    [] of String
  end

  @body_height = height
  @scrollable_lines = body.size

  max_offset = @scrollable_lines - @body_height
  max_offset = 0 if max_offset < 0
  @scroll_offset = 0 if @scroll_offset < 0
  @scroll_offset = max_offset if @scroll_offset > max_offset

  visible_end = @scrollable_lines - @scroll_offset
  visible_start = visible_end - @body_height
  visible_start = 0 if visible_start < 0
  visible_count = visible_end - visible_start

  visible_lines = Array(String).new(visible_count) do |index|
    body[visible_start + index]
  end

  # The running placeholder occupies a screen row, but is not output data.
  total_lines = displayed_output.nil? ? 0 : body.size
  first_line = if total_lines > 0 && visible_count > 0
    visible_start + 1
  end
  last_line = first_line ? visible_start + visible_count : nil

  Viewport.new(visible_lines, total_lines, first_line, last_line)
end

# Compose fixed sections around the viewport without changing their contents.
private def compose_frame(
  header : Array(String),
  viewport : Viewport,
  footer : Array(String)
) : Array(String)
  frame = header.dup
  frame.concat(viewport.lines)
  frame.concat(footer)
  frame
end

# Rewrite each row in place and flush once per complete frame.
private def write_frame(io : IO, lines : Array(String), height : Int32) : Nil
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
