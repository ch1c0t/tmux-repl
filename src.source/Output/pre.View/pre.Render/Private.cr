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

  header = header_lines(sequence, command, mode_label, screen_width)
  footer = footer_lines(sequence, screen_width)

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
private def header_lines(
  sequence : UInt64,
  command : String,
  mode_label : String,
  width : Int32
) : Array(String)
  wrap_label = @wrap_lines ? "WRAP" : "NO-WRAP"
  [
    "INPUT ##{sequence} [#{mode_label}; #{wrap_label}]",
    *output_lines(command),
    "─" * width,
  ]
end

# Keep the footer to the boundary, combined controls/status row, and line summary.
private def footer_lines(sequence : UInt64, width : Int32) : Array(String)
  controls = if @wrap_lines
    "[WRAP · Up/Down: scroll · Ctrl+W: no-wrap · Ctrl+L: list]"
  else
    "[NO-WRAP · ←/→: horizontal · Home/End: edges · Ctrl+W: wrap]"
  end
  if status = @statuses[sequence]?
    controls = "[exit status: #{status}] · #{controls}"
  end
  lines = ["─" * width, controls, ""]
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
  active_styles = [] of String
  lines.each_with_index do |line, index|
    rendered = if @wrap_lines
      wrap_line(line, width, active_styles)
    else
      [horizontal_line(line, width, active_styles)]
    end
    rendered.each { |row| rows << {row, index} }
  end
  rows
end

private def viewport_row_count(text : String, width : Int32) : Int32
  viewport_rows(output_lines(text), width).size
end

# Split a logical line without counting or splitting terminal control sequences.
private def wrap_line(line : String, width : Int32, active_styles : Array(String)) : Array(String)
  width = 1 if width < 1
  rows = [] of String
  current = String::Builder.new
  active_styles.each { |style| current << style }
  current_width = 0

  terminal_units(line).each do |token, token_width, control|
    if control
      current << token
      update_active_styles(active_styles, token)
      next
    end

    if token_width > 0 && current_width > 0 && current_width + token_width > width
      current << "\e[0m" if active_styles.any?
      rows << current.to_s
      current = String::Builder.new
      active_styles.each { |style| current << style }
      current_width = 0
    end

    current << token
    current_width += token_width
  end

  current << "\e[0m" if active_styles.any?
  rows << current.to_s
  rows
end

# Keep one visual row and mark hidden content at either edge.
private def horizontal_line(line : String, width : Int32, active_styles : Array(String)) : String
  line_width = display_width(line)
  left_marker = @horizontal_offset > 0
  content_width = width - (left_marker ? 1 : 0)
  remaining_width = line_width - @horizontal_offset
  right_marker = remaining_width > content_width
  content_width -= 1 if right_marker
  content = slice_display_columns(line, @horizontal_offset, content_width, active_styles)

  String.build do |buffer|
    buffer << "‹" if left_marker
    buffer << content
    buffer << "›" if right_marker
  end
end

private def display_width(text : String) : Int32
  width = 0
  terminal_units(text).each { |_, token_width, _| width += token_width }
  width
end

# Tokenize ANSI sequences separately so they never occupy terminal columns.
private def terminal_units(text : String) : Array(Tuple(String, Int32, Bool))
  characters = text.chars
  units = [] of Tuple(String, Int32, Bool)
  index = 0

  while index < characters.size
    if characters[index] == '\e'
      ending = ansi_sequence_end(characters, index)
      break unless ending

      units << {characters[index, ending - index].join, 0, true}
      index = ending
    else
      char = characters[index]
      units << {char.to_s, terminal_character_width(char), false}
      index += 1
    end
  end

  units
end

# Return the end of a complete 7-bit ANSI sequence; incomplete tails are buffered
# by omission until the next streamed chunk completes them.
private def ansi_sequence_end(characters : Array(Char), start : Int32) : Int32?
  introducer = characters[start + 1]?
  return nil unless introducer

  case introducer
  when '['
    index = start + 2
    while index < characters.size
      return index + 1 if (0x40..0x7e).includes?(characters[index].ord)
      index += 1
    end
  when ']', 'P', 'X', '^', '_'
    index = start + 2
    while index < characters.size
      char = characters[index]
      return index + 1 if introducer == ']' && char == '\a'
      return index + 2 if char == '\e' && characters[index + 1]? == '\\'
      index += 1
    end
  else
    index = start + 1
    while index < characters.size && (0x20..0x2f).includes?(characters[index].ord)
      index += 1
    end
    return index + 1 if index < characters.size && (0x30..0x7e).includes?(characters[index].ord)
  end

  nil
end

# Retain the SGR sequences needed to restore the current style after a wrapped
# or horizontally clipped row. A leading reset starts a fresh style run.
private def update_active_styles(styles : Array(String), sequence : String) : Nil
  return unless sequence.starts_with?("\e[") && sequence.ends_with?('m')

  parameters = sequence[2...-1]
  first_parameter = parameters.split(';').first?
  if first_parameter.nil? || first_parameter.empty? || first_parameter == "0"
    styles.clear
    styles << sequence unless parameters.empty? || parameters == "0"
  else
    styles << sequence unless styles.last? == sequence
  end
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

# Extract complete characters by display column while preserving SGR state.
private def slice_display_columns(
  text : String,
  start_column : Int32,
  width : Int32,
  active_styles : Array(String) = [] of String
) : String
  column = 0
  visible_width = 0
  visible = false
  clipped = false
  visible_styles = [] of String

  String.build do |buffer|
    terminal_units(text).each do |token, token_width, control|
      if control
        if visible && !clipped
          buffer << token
          update_active_styles(visible_styles, token)
        end
        update_active_styles(active_styles, token)
        next
      end

      if token_width == 0
        buffer << token if visible && !clipped
        next
      end

      if column + token_width <= start_column
        column += token_width
        next
      end

      if column < start_column
        column += token_width
        next
      end

      if !clipped && visible_width + token_width <= width
        unless visible
          active_styles.each do |style|
            buffer << style
            visible_styles << style
          end
          visible = true
        end
        buffer << token
        visible_width += token_width
      else
        clipped = true
      end
      column += token_width
    end

    buffer << "\e[0m" if visible && visible_styles.any?
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
