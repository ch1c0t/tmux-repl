# Assemble the four visible components for one selected input.
private def render_selected(
  io : IO,
  sequence : UInt64,
  command : String,
  screen_height : Int32,
  screen_width : Int32
) : Nil
  completed = @statuses.has_key?(sequence)
  displayed_output, mode_label = displayed_output_for(sequence, completed)

  header = header_lines(sequence, command, mode_label)
  footer = footer_lines(sequence)

  header, footer, body_height = fit_sections(header, footer, screen_height)
  viewport = build_viewport(displayed_output, completed, body_height, screen_width)
  footer[-1] = viewport.line_summary(completed)

  write_frame(io, compose_frame(header, viewport, footer), screen_height, screen_width)
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
  wrap_label = @wrap_lines ? "WRAP" : "NO-WRAP"
  [
    "INPUT ##{sequence} [#{mode_label}; #{wrap_label}]",
    *output_lines(command),
    "─" * 40,
  ]
end

# Keep the footer to one control row plus the exit status and line summary.
private def footer_lines(sequence : UInt64) : Array(String)
  controls = if @wrap_lines
    "[WRAP · Up/Down: scroll · Ctrl+W: no-wrap · Ctrl+L: list]"
  else
    "[NO-WRAP · ←/→: horizontal · Home/End: edges · Ctrl+W: wrap]"
  end
  lines = [controls]
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
  height : Int32,
  width : Int32
) : Viewport
  body = if output = displayed_output
    output_lines(output)
  elsif !completed
    ["(running...)"]
  else
    [] of String
  end

  if !@wrap_lines
    widest_line = body.max_of? { |line| display_width(line) } || 0
    max_offset = widest_line - (width - 1)
    max_offset = 0 if max_offset < 0
    @horizontal_offset = max_offset if @horizontal_offset > max_offset
  else
    @horizontal_offset = 0
  end

  rows = viewport_rows(body, width)
  @body_height = height
  @scrollable_lines = rows.size

  max_offset = @scrollable_lines - @body_height
  max_offset = 0 if max_offset < 0
  @scroll_offset = 0 if @scroll_offset < 0
  @scroll_offset = max_offset if @scroll_offset > max_offset

  visible_end = @scrollable_lines - @scroll_offset
  visible_start = visible_end - @body_height
  visible_start = 0 if visible_start < 0
  visible_count = visible_end - visible_start

  visible_lines = [] of String
  first_line : Int32? = nil
  last_line : Int32? = nil
  visible_count.times do |index|
    row = rows[visible_start + index]
    visible_lines << row[0]
    logical_line = row[1] + 1
    first_line ||= logical_line
    last_line = logical_line
  end

  # The running placeholder occupies a screen row, but is not output data.
  total_lines = displayed_output.nil? ? 0 : body.size
  Viewport.new(visible_lines, total_lines, first_line, last_line)
end

# Convert logical lines into terminal rows while retaining their original line numbers.
private def viewport_rows(lines : Array(String), width : Int32) : Array(Tuple(String, Int32))
  rows = [] of Tuple(String, Int32)
  lines.each_with_index do |line, index|
    rendered = if @wrap_lines
      wrap_line(line, width)
    else
      [horizontal_line(line, width)]
    end
    rendered.each { |row| rows << {row, index} }
  end
  rows
end

private def viewport_row_count(text : String, width : Int32) : Int32
  viewport_rows(output_lines(text), width).size
end

# Split a logical line without losing or rewriting its original content.
private def wrap_line(line : String, width : Int32) : Array(String)
  width = 1 if width < 1
  rows = [] of String
  current = [] of Char
  current_width = 0

  line.each_char do |char|
    char_width = terminal_character_width(char)
    if current_width > 0 && current_width + char_width > width
      rows << current.join
      current.clear
      current_width = 0
    end
    current << char
    current_width += char_width
  end

  rows << current.join
  rows
end

# Keep a single visual row and mark hidden content at either edge.
private def horizontal_line(line : String, width : Int32) : String
  line_width = display_width(line)
  return line if @horizontal_offset == 0 && line_width <= width

  left_marker = @horizontal_offset > 0
  content_width = width - (left_marker ? 1 : 0)
  remaining_width = line_width - @horizontal_offset
  right_marker = remaining_width > content_width
  content_width -= 1 if right_marker
  content = slice_display_columns(line, @horizontal_offset, content_width)

  String.build do |buffer|
    buffer << "‹" if left_marker
    buffer << content
    buffer << "›" if right_marker
  end
end

private def display_width(text : String) : Int32
  width = 0
  text.each_char { |char| width += terminal_character_width(char) }
  width
end

# Approximate terminal cell width: combining marks are zero, East Asian wide
# characters and emoji are two, and ordinary printable characters are one.
private def terminal_character_width(char : Char) : Int32
  codepoint = char.ord

  return 0 if codepoint < 0x20 || (codepoint >= 0x7f && codepoint < 0xa0)
  return 0 if (0x0300..0x036f).includes?(codepoint) ||
              (0x1ab0..0x1aff).includes?(codepoint) ||
              (0x1dc0..0x1dff).includes?(codepoint) ||
              (0x20d0..0x20ff).includes?(codepoint) ||
              (0xfe00..0xfe0f).includes?(codepoint) ||
              (0xfe20..0xfe2f).includes?(codepoint) ||
              (0xe0100..0xe01ef).includes?(codepoint) ||
              codepoint == 0x200d

  return 2 if (0x1100..0x115f).includes?(codepoint) ||
              codepoint == 0x2329 || codepoint == 0x232a ||
              (0x2e80..0xa4cf).includes?(codepoint) ||
              (0xac00..0xd7a3).includes?(codepoint) ||
              (0xf900..0xfaff).includes?(codepoint) ||
              (0xfe10..0xfe19).includes?(codepoint) ||
              (0xfe30..0xfe6f).includes?(codepoint) ||
              (0xff00..0xff60).includes?(codepoint) ||
              (0xffe0..0xffe6).includes?(codepoint) ||
              (0x1f300..0x1faff).includes?(codepoint) ||
              (0x20000..0x3fffd).includes?(codepoint)

  1
end

# Extract only complete characters that fit in the requested display columns.
private def slice_display_columns(text : String, start_column : Int32, width : Int32) : String
  return "" if width <= 0

  column = 0
  visible_width = 0
  String.build do |buffer|
    text.each_char do |char|
      char_width = terminal_character_width(char)

      if column + char_width <= start_column
        column += char_width
        next
      end

      if column < start_column && char_width > 0
        column += char_width
        next
      end

      break if char_width > 0 && visible_width + char_width > width

      buffer << char
      visible_width += char_width
      column += char_width
    end
  end
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

# Rewrite each row in place, clipping it before the terminal can auto-wrap it.
private def write_frame(io : IO, lines : Array(String), height : Int32, width : Int32) : Nil
  output = String.build do |buffer|
    height.times do |index|
      line = lines[index]? || ""
      buffer << "\e[" << (index + 1) << ";1H"
      buffer << fit_frame_line(line, width)
      buffer << "\e[0K"
    end
  end
  io.print output
  io.flush
end

private def fit_frame_line(line : String, width : Int32) : String
  return "" if width <= 0
  return line if display_width(line) <= width

  slice_display_columns(line, 0, width - 1) + "…"
end

# Show every submitted input with its execution state and a short output preview.
private def render_output_list(io : IO, height : Int32, width : Int32) : Nil
  sequences = @inputs.keys.sort
  if sequences.empty?
    write_frame(io, ["AVAILABLE OUTPUTS (0)", "No outputs have been submitted.", "[Ctrl+L: return]"], height, width)
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
    rows << output_list_line(sequences[visible_start + index], width)
  end

  footer[-1] = if visible_count == 0
    "[0 of #{sequences.size} outputs visible]"
  else
    "[Outputs #{visible_start + 1}–#{visible_end} of #{sequences.size}]"
  end

  frame = header.dup
  frame.concat(rows)
  frame.concat(footer)
  write_frame(io, frame, height, width)
end

private def output_list_line(sequence : UInt64, width : Int32) : String
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
  truncate_list_line(line, width)
end

private def truncate_list_line(line : String, width : Int32) : String
  return "" if width <= 0
  return line if display_width(line) <= width
  return slice_display_columns(line, 0, width) if width == 1

  slice_display_columns(line, 0, width - 1) + "…"
end

private def usable_width(width : Int32) : Int32
  width = width - 1
  width > 0 ? width : 1
end

private def terminal_width : Int32
  width = Tmux::Pane.from_env.width
  width > 0 ? width : 80
rescue
  ENV["COLUMNS"]?.try(&.to_i?) || 80
end
