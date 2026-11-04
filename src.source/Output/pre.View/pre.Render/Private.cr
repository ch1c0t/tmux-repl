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
  lines = ["[Ctrl+L: list outputs · Up/Down: scroll; PageUp/PageDown: page]"]
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

# Show every submitted input with its execution state and a short output preview.
private def render_output_list(io : IO, height : Int32) : Nil
  sequences = @inputs.keys.sort
  if sequences.empty?
    write_frame(io, ["AVAILABLE OUTPUTS (0)", "No outputs have been submitted.", "[Ctrl+L: return]"], height)
    return
  end

  header = [
    "AVAILABLE OUTPUTS (#{sequences.size})",
    "[Up/Down: scroll · PageUp/PageDown: page · Ctrl+L: return]",
    "─" * 40,
  ]
  footer = [
    "* = currently displayed output",
    "",
  ]

  footer = footer.last(height)
  header_limit = height - footer.size - 1
  header_limit = 0 if header_limit < 0
  header = header.first(header_limit) if header.size > header_limit

  @list_body_height = height - header.size - footer.size
  @list_scrollable_lines = sequences.size

  max_offset = @list_scrollable_lines - @list_body_height
  max_offset = 0 if max_offset < 0
  @list_scroll_offset = 0 if @list_scroll_offset < 0
  @list_scroll_offset = max_offset if @list_scroll_offset > max_offset

  visible_end = @list_scrollable_lines - @list_scroll_offset
  visible_start = visible_end - @list_body_height
  visible_start = 0 if visible_start < 0
  visible_count = visible_end - visible_start

  rows = Array(String).new(visible_count)
  visible_count.times do |index|
    rows << output_list_line(sequences[visible_start + index])
  end

  footer[-1] = if visible_count == 0
    "[0 of #{sequences.size} outputs visible]"
  else
    "[Outputs #{visible_start + 1}–#{visible_end} of #{sequences.size}]"
  end

  frame = header.dup
  frame.concat(rows)
  frame.concat(footer)
  write_frame(io, frame, height)
end

private def output_list_line(sequence : UInt64) : String
  marker = sequence == @selected_sequence ? "*" : " "
  status = if exit_status = @statuses[sequence]?
    "EXIT #{exit_status}"
  else
    "RUNNING"
  end

  output = if @statuses.has_key?(sequence) && !@raw_view
    @clean_outputs[sequence]? || @outputs[sequence]?
  else
    @outputs[sequence]?
  end
  visible_output_lines = output ? output_lines(output) : [] of String
  preview = visible_output_lines.first? || "(no output yet)"
  command = @inputs[sequence].gsub(/[\r\n\t ]+/, " ").strip

  line = "#{marker} ##{sequence} [#{status}] #{visible_output_lines.size} lines | #{command} → #{preview}"
  truncate_list_line(line, terminal_width)
end

private def truncate_list_line(line : String, width : Int32) : String
  return "" if width <= 0

  characters = line.chars
  return line if characters.size <= width
  return characters.first(width).join if width == 1

  characters.first(width - 1).join + "…"
end

private def terminal_width : Int32
  width = Tmux::Pane.from_env.width
  width > 0 ? width : 80
rescue
  ENV["COLUMNS"]?.try(&.to_i?) || 80
end
