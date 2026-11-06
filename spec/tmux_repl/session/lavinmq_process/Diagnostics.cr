module LavinMQProcess
  module DiagnosticFormatting
    def self.table(
      title : String,
      headers : Array(String),
      rows : Array(Array(String)),
      widths : Array(Int32)
    ) : String
      raise ArgumentError.new("Column widths must match the headers.") unless headers.size == widths.size
      raise ArgumentError.new("Every column must have a positive width.") unless widths.all? { |width| width > 0 }
      raise ArgumentError.new("Every row must match the number of headers.") unless rows.all? { |row| row.size == headers.size }

      String.build do |io|
        io << heading_border(title, widths) << '\n'
        io << table_row(headers, widths) << '\n'
        io << separator(widths) << '\n'

        rows.each_with_index do |row, index|
          io << table_row(row, widths)
          io << '\n' unless index == rows.size - 1
        end

        io << separator(widths)
      end
    end

    def self.frame(title : String, contents : String, width : Int32 = 96) : String
      width = 1 if width < 1
      lines = [] of String

      contents.split('\n', remove_empty: false).each do |line|
        characters = line.chars
        if characters.empty?
          lines << ""
          next
        end

        offset = 0
        while offset < characters.size
          lines << characters[offset, width].join
          offset += width
        end
      end

      String.build do |io|
        io << heading_border(title, [width]) << '\n'

        lines.each do |line|
          io << "| " << line
          io << " " * (width - line.chars.size)
          io << " |\n"
        end

        io << separator([width])
      end
    end

    # Parses one key=value trace record without splitting a character value
    # such as character=' ' on its embedded space.
    def self.keyboard_event_row(line : String) : Array(String)
      parts = line.split(" pane=", 2)
      return unparsed_keyboard_event(line) unless parts.size == 2

      timestamp = parts[0].sub("pressed_at=", "")
      parts = parts[1].split(" pid=", 2)
      return unparsed_keyboard_event(line) unless parts.size == 2
      pane = parts[0]

      parts = parts[1].split(" ", 2)
      return unparsed_keyboard_event(line) unless parts.size == 2
      pid = parts[0]

      parts = parts[1].split(" action=", 2)
      return unparsed_keyboard_event(line) unless parts.size == 2
      input = parts[0].sub(/^key=/, "").sub(/^character=/, "")

      parts = parts[1].split(" elapsed_since_previous_ms=", 2)
      return unparsed_keyboard_event(line) unless parts.size == 2
      action = parts[0]

      parts = parts[1].split(" result=", 2)
      return unparsed_keyboard_event(line) unless parts.size == 2
      elapsed = parts[0]
      result = parts[1]

      clock = timestamp.split('T').last
      clock = clock[0, clock.size - 1] if clock.ends_with?("Z")

      [clock, pane, pid, input, action, elapsed, result]
    end

    private def self.unparsed_keyboard_event(line : String) : Array(String)
      ["?", "?", "?", "?", "unparsed", "-", line]
    end

    private def self.heading_border(title : String, widths : Array(Int32)) : String
      total_width = widths.reduce(0) { |sum, width| sum + width } + widths.size * 3 + 1
      label = fit(title, total_width - 6)
      "+-- #{label} " + "-" * (total_width - label.chars.size - 6) + "+"
    end

    private def self.separator(widths : Array(Int32)) : String
      "+" + widths.map { |width| "-" * (width + 2) }.join("+") + "+"
    end

    private def self.table_row(values : Array(String), widths : Array(Int32)) : String
      String.build do |io|
        io << "|"

        widths.each_with_index do |width, index|
          value = fit(values[index].gsub("\n", "\\n"), width)
          io << " " << value << " " * (width - value.chars.size) << " |"
        end
      end
    end

    private def self.fit(value : String, width : Int32) : String
      characters = value.chars
      return value if characters.size <= width
      return characters[0, width].join if width <= 3

      characters[0, width - 3].join + "..."
    end
  end

  module Diagnostics
    private def diagnostic_details(
      message : String,
      pane_snapshots : Hash(String, String)
    ) : String
      details = [
        DiagnosticFormatting.frame("FAILURE", message),
        DiagnosticFormatting.table(
          "SCENARIO",
          ["Property", "Value"],
          [
            ["Name", name],
            ["Stage", @stage],
            ["State home", @state_home],
            ["Worker PID file", @worker_pid_path],
          ],
          [18, 72]
        ),
        process_snapshot,
        pane_snapshot("input", @input_pane, pane_snapshots),
        pane_snapshot("output", @output_pane, pane_snapshots),
        keyboard_trace_snapshot,
        tmux_snapshot,
        message_stream_snapshot,
      ]

      details.join("\n\n")
    end

    private def process_snapshot : String
      rows = @ready_paths.map do |path|
        pid = file_state(path)
        status = if pid == "missing"
                   "MISSING"
                 elsif pid.starts_with?("unreadable")
                   "UNREADABLE"
                 elsif pid.empty?
                   "EMPTY"
                 else
                   "READY"
                 end

        [File.basename(path, ".pid"), pid, status]
      end

      DiagnosticFormatting.table(
        "PROCESS STATE",
        ["Process", "PID file value", "Status"],
        rows,
        [12, 24, 12]
      )
    end

    private def pane_snapshot(
      label : String,
      pane : Tmux::Pane?,
      pane_snapshots : Hash(String, String)
    ) : String
      return DiagnosticFormatting.frame("#{label.upcase} PANE", "not attached yet") unless pane

      metadata = [
        ["Pane ID", pane.pane_id],
        ["Window ID", pane.window_id],
        ["Index", pane_value { pane.pane_index.to_s }],
        ["Size", pane_value { "#{pane.width}x#{pane.height}" }],
        ["Active", pane_value { pane.active?.to_s }],
        ["Capture", pane_snapshots.has_key?(label) ? "assertion-time" : "diagnostic-time"],
      ]

      contents = pane_snapshots[label]? || pane_text(pane)
      metadata_table = DiagnosticFormatting.table(
        "#{label.upcase} PANE",
        ["Property", "Value"],
        metadata,
        [16, 72]
      )
      contents_frame = DiagnosticFormatting.frame("#{label.upcase} PANE CONTENTS", contents)

      "#{metadata_table}\n#{contents_frame}"
    rescue ex
      DiagnosticFormatting.frame(
        "#{label.upcase} PANE CAPTURE ERROR",
        "#{ex.class}: #{ex.message}"
      )
    end

    private def pane_value(&block : -> String) : String
      yield
    rescue ex
      "unavailable (#{ex.class}: #{ex.message})"
    end

    private def keyboard_trace_snapshot : String
      state_dir = TmuxREPL::State.session_path(name)
      path = File.join(state_dir, "logs", "keyboard.trace.log")
      return DiagnosticFormatting.frame("KEYBOARD TRACE", "missing: #{path}") unless File.exists?(path)

      trace_lines = File.read(path).lines.last(30)
      rows = trace_lines.map do |line|
        DiagnosticFormatting.keyboard_event_row(line.chomp)
      end

      DiagnosticFormatting.table(
        "KEYBOARD TRACE / LAST #{rows.size} EVENTS / DELTA PER PANE",
        ["Time", "Pane", "PID", "Input", "Action", "Delta ms", "Result"],
        rows,
        [15, 6, 7, 10, 18, 8, 24]
      )
    rescue ex
      DiagnosticFormatting.frame(
        "KEYBOARD TRACE CAPTURE ERROR",
        "#{ex.class}: #{ex.message}"
      )
    end

    private def tmux_snapshot : String
      result = @server.cmd("list-sessions")
      output = result.stdout.strip
      output = "(no session listing output)" if output.empty?

      metadata = DiagnosticFormatting.table(
        "TMUX SERVER",
        ["Property", "Value"],
        [
          ["Command", "list-sessions"],
          ["Success", result.success?.to_s],
        ],
        [16, 72]
      )
      sessions = DiagnosticFormatting.frame("TMUX SESSIONS", output)
      "#{metadata}\n#{sessions}"
    rescue ex
      DiagnosticFormatting.frame(
        "TMUX SESSION LISTING ERROR",
        "#{ex.class}: #{ex.message}"
      )
    end

    private def message_stream_snapshot : String
      channel = Global.amqp_channel
      commands_name = TmuxREPL.commands_queue_name(name)
      events_name = TmuxREPL.events_queue_name(name)
      commands = TmuxREPL.stream_queue(channel, commands_name)
      events = TmuxREPL.stream_queue(channel, events_name)

      DiagnosticFormatting.table(
        "LAVINMQ STREAMS",
        ["Stream", "Queue", "Messages"],
        [
          ["Commands", commands_name, commands.message_count.to_s],
          ["Events", events_name, events.message_count.to_s],
        ],
        [12, 48, 10]
      )
    rescue ex
      DiagnosticFormatting.frame(
        "LAVINMQ STREAMS ERROR",
        "#{ex.class}: #{ex.message}"
      )
    end

    private def file_state(path : String) : String
      File.exists?(path) ? File.read(path).strip : "missing"
    rescue ex
      "unreadable (#{ex.class}: #{ex.message})"
    end

    private def fail_with_diagnostics(
      message : String,
      pane_snapshots : Hash(String, String) = {} of String => String
    ) : Nil
      raise diagnostic_details(message, pane_snapshots)
    end

    private def expect_condition(condition : Bool, description : String) : Nil
      return if condition

      fail_with_diagnostics(description)
    end

    private def expect_equal(expected : T, actual : T, description : String) : Nil forall T
      return if expected == actual

      fail_with_diagnostics(
        "#{description}\nExpected: #{expected.inspect}\nActual: #{actual.inspect}"
      )
    end

    private def expect_pane(
      pane : Tmux::Pane,
      label : String,
      expected : Array(String),
      timeout : Time::Span = 5.seconds
    ) : Nil
      last_text = ""
      capture_error : String? = nil

      matched = wait_until(timeout, 25.milliseconds) do
        begin
          last_text = pane_text(pane)
          expected.all? { |text| last_text.includes?(text) }
        rescue ex
          capture_error = "#{ex.class}: #{ex.message}"
          false
        end
      end
      return if matched

      missing = expected.reject { |text| last_text.includes?(text) }
      message = [
        "Timed out after #{timeout} waiting for the #{label} pane.",
        "Expected to find: #{expected.map(&.inspect).join(", ")}",
        "Still missing: #{missing.map(&.inspect).join(", ")}",
      ]
      message << "Last pane capture error: #{capture_error}" if capture_error

      fail_with_diagnostics(message.join("\n"), {label => last_text})
    end

    private def expect_output(*expected : String, timeout : Time::Span = 5.seconds) : Nil
      expect_pane(output_pane, "output", expected.to_a, timeout)
    end

    private def expect_input(*expected : String, timeout : Time::Span = 5.seconds) : Nil
      expect_pane(input_pane, "input", expected.to_a, timeout)
    end

    private def expect_output_without(marker : String) : Nil
      actual = pane_text(output_pane)
      return unless actual.includes?(marker)

      fail_with_diagnostics(
        "Expected the output pane not to contain #{marker.inspect}, but it did.",
        {"output" => actual}
      )
    rescue ex
      raise ex if ex.message.to_s.starts_with?("+-- FAILURE")

      fail_with_diagnostics(
        "Could not verify that the output pane excludes #{marker.inspect}: " +
        "#{ex.class}: #{ex.message}"
      )
    end
  end
end
