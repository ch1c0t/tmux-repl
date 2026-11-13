require "io/memory"
require "json"
require "sync/mutex"
require "./tmux_repl"

module Output
  # Output-pane process implementation and rendering.

  class DesktopNotification
    getter notify_send_path : String
    
    def initialize(@notify_send_path : String = ENV["TMUX_REPL_NOTIFY_SEND"]? || "notify-send")
    end
    
    # Display a short confirmation outside the tmux pane. Notification delivery
    # is optional and must never affect a successful clipboard operation.
    def output_copied : Bool
      status = Process.run(
        @notify_send_path,
        [
          "--app-name=tmux.repl",
          "--urgency=low",
          "--expire-time=1500",
          "Output copied",
          "Available in X11 CLIPBOARD and PRIMARY.",
        ],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )
      status.success?
    rescue
      false
    end
  end

  class Runner
    module Consume
      private def handle_message(
        message : AMQP::Client::DeliverMessage,
        view : View
      ) : Nil
        begin
          data = JSON.parse(message.body_io.to_s)
          sequence = data["sequence"].as_i64.to_u64
          event_type = data["type"].as_s
          event_received_at = Time.instant if TmuxREPL.trace_timing_enabled?
      
          if event_type == "toggle_output_zoom"
            toggle_output_zoom(view, data)
          elsif event_type == "yank_output"
            yank_output(view)
          else
            view.update(data)
      
            render_started_at = Time.instant if TmuxREPL.trace_timing_enabled?
            view.render
            if render_started = render_started_at
              TmuxREPL.trace_timing(
                @session_name, "output", "event_rendered", render_started,
                "type=#{event_type} sequence=#{sequence}"
              )
            end
          end
          if event_started = event_received_at
            TmuxREPL.trace_timing(
              @session_name, "output", "event_handled", event_started,
              "type=#{event_type} sequence=#{sequence}"
            )
          end
          message.ack
        rescue ex
          STDERR.puts "tmux.repl.output: invalid event: #{ex.message}"
          begin
            message.reject(requeue: false)
          rescue
          end
        end
      end
      
      
      # Copy the complete selected output to both X11 selections.
      private def yank_output(view : View) : Nil
        unless output = view.current_output
          return
        end
      
        X11Clipboard.new.copy(output)
        DesktopNotification.new.output_copied
        nil
      rescue ex
        record_yank_failure(ex)
      end
      
      # Keep yank failures out of the rendered terminal pane.
      private def record_yank_failure(exception : Exception) : Nil
        File.open(File.join(state_dir, "output.yank.log"), "a") do |file|
          file.puts("#{Time.utc}: #{exception.class}: #{exception.message}")
        end
      rescue
      end
      
      # Alt+Z always zooms the Output pane. Remember the pane that requested the
      # zoom so the second Alt+Z restores focus after removing the zoom.
      private def toggle_output_zoom(view : View, data : JSON::Any) : Nil
        pane = Tmux::Pane.from_env
        zoomed = pane.display_message("\#{window_zoomed_flag}") == "1"
      
        if zoomed
          pane.run!("resize-pane", "-Z", "-t", pane.pane_id)
          if return_pane_id = @zoom_return_pane_id
            pane.run!("select-pane", "-t", return_pane_id)
          end
          @zoom_return_pane_id = nil
        else
          @zoom_return_pane_id = data["requesting_pane"]?.try(&.as_s)
          pane.select
          pane.run!("resize-pane", "-Z", "-t", pane.pane_id)
        end
      
        view.render
      end
    end
  
    module Helpers
      private def state_dir : String
        @state.base_path
      end
      
      private def output_pid_path : String
        File.join(state_dir, "output.pid")
      end
      
      private def startup_error_path : String
        File.join(state_dir, "output.error")
      end
      
      private def startup_stage_path : String
        File.join(state_dir, "output.startup")
      end
      
      private def prepare_startup : Nil
        File.delete(startup_error_path) if File.exists?(startup_error_path)
        update_startup_stage("connecting to LavinMQ")
      end
      
      private def update_startup_stage(stage : String) : Nil
        File.write(startup_stage_path, stage)
      end
      
      private def mark_ready : Nil
        File.write(output_pid_path, Process.pid.to_s)
        File.delete(startup_stage_path) if File.exists?(startup_stage_path)
      end
      
      private def report_startup_failure(exception : Exception) : Nil
        File.write(startup_error_path, "#{exception.class}: #{exception.message}")
        STDERR.puts "tmux.repl.output: #{exception.class}: #{exception.message}"
      end
      
      private def unsubscribe(
        event_queue : AMQP::Client::Queue?,
        consumer_tag : String?
      ) : Nil
        return unless queue = event_queue
        return unless tag = consumer_tag
      
        begin
          queue.unsubscribe(tag)
        rescue
        end
      end
      
      private def cleanup_readiness : Nil
        File.delete(output_pid_path) if File.exists?(output_pid_path)
      end
    end
  
    module Keyboard
      private def watch_keyboard(
        dispatcher : TmuxREPL::Keyboard::Dispatcher,
        terminal_mode : TmuxREPL::TerminalMode
      ) : Nil
        return unless terminal_mode.enable
      
        spawn do
          pending = [] of UInt8
          buffer = Bytes.new(128)
      
          begin
            loop do
              count = STDIN.read(buffer)
              break if count == 0
      
              count.times { |index| pending << buffer[index] }
              dispatch_keyboard_input(pending, dispatcher)
            end
            dispatch_keyboard_input(pending, dispatcher, flush: true)
          rescue IO::Error
            # The pane may close while the keyboard reader is waiting.
          ensure
            terminal_mode.restore
          end
        end
      end
      
      # Keep incomplete escape-sequence prefixes until the next read. This handles
      # arrow and page-key sequences even when the PTY splits them across reads.
      private def dispatch_keyboard_input(
        pending : Array(UInt8),
        dispatcher : TmuxREPL::Keyboard::Dispatcher,
        flush : Bool = false
      ) : Nil
        until pending.empty?
          input = String.build do |io|
            pending.each { |byte| io.write_byte(byte) }
          end
      
          if match = TmuxREPL::Keyboard.output_sequence_match(input)
            sequence, binding = match
            sequence.bytesize.times { pending.shift }
            dispatcher.enqueue(binding)
          elsif !flush && TmuxREPL::Keyboard.output_sequence_prefix?(input)
            break
          else
            dispatcher.enqueue(pending.shift.chr)
          end
        end
      end
    end
  
    module Run
      # Connect to the event stream, render its events, and stay alive with the tmux session.
      def run : Nil
        prepare_startup
        event_queue : AMQP::Client::Queue? = nil
        consumer_tag : String? = nil
        dispatcher : TmuxREPL::Keyboard::Dispatcher? = nil
        terminal_mode = TmuxREPL::TerminalMode.new
        cursor_hidden = false
      
        begin
          channel = Global.amqp_channel
          channel.prefetch(32)
      
          update_startup_stage("declaring event stream")
          queue = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(@session_name))
          event_queue = queue
          view = View.new
          shutdown = Channel(Nil).new(1)
      
          Process.on_terminate do |_reason|
            shutdown.send(nil)
          end
      
          update_startup_stage("subscribing to event stream")
          consumer_tag = queue.subscribe(
            no_ack: false,
            block: false,
            args: AMQ::Protocol::Table.new({"x-stream-offset" => "next"} of String => AMQ::Protocol::Field)
          ) do |message|
            handle_message(message, view)
          end
      
          on_action = ->(action : TmuxREPL::Keyboard::Action) do
            if action == TmuxREPL::Keyboard::Action::YankOutput
              yank_output(view)
            else
              view.render if view.scroll(action)
            end
            nil
          end
          dispatcher = TmuxREPL::Keyboard::Dispatcher.new(@session_name, "output", queue, on_action)
          dispatcher.start
      
          STDOUT.print "\e[?25l"
          STDOUT.flush
          cursor_hidden = true
      
          view.render
          watch_keyboard(dispatcher, terminal_mode)
          mark_ready
          shutdown.receive
        rescue ex
          report_startup_failure(ex)
          exit 1
        ensure
          begin
            dispatcher.try &.stop
          ensure
            terminal_mode.restore
            if cursor_hidden
              STDOUT.print "\e[?25h"
              STDOUT.flush
            end
            unsubscribe(event_queue, consumer_tag)
            cleanup_readiness
          end
        end
      end
    end
  
    getter session_name : String
    
    @zoom_return_pane_id : String?
    
    def initialize(@session_name : String)
      @state = TmuxREPL::State.open(@session_name)
      @zoom_return_pane_id = nil
    end
    
    include Helpers
    include Consume
    include Keyboard
    include Run
  end

  class View
    module Render
      struct Viewport
        # The viewport owns scrolling, visible-line selection, and logical line numbering.
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
    
      module Private
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
      end
    
      # Render the selected input as a fixed header, scrollable viewport, and footer.
      def render(io : IO = STDOUT, height : Int32? = nil, width : Int32? = nil) : Nil
        @mutex.synchronize do
          screen_height = height || terminal_height
          screen_height = 1 if screen_height < 1
          screen_width = usable_width(width || terminal_width)
          @render_width = screen_width
      
          if @list_view
            render_output_list(io, screen_height, screen_width)
            next
          end
      
          unless selected = @selected_sequence
            write_frame(io, ["No inputs yet."], screen_height, screen_width)
            next
          end
      
          unless command = @inputs[selected]?
            write_frame(io, ["Waiting for input ##{selected}..."], screen_height, screen_width)
            next
          end
      
          render_selected(io, selected, command, screen_height, screen_width)
        end
      end
      
      include Private
    end
  
    module Update
      # Apply one event from the session event stream to the displayed view.
      def update(event : JSON::Any) : Nil
        @mutex.synchronize do
          sequence = event["sequence"].as_i64.to_u64
      
          case event["type"].as_s
          when "input"
            @list_scroll_offset += 1 if @list_view && @list_scroll_offset > 0
            @scroll_offset = 0 if @selected_sequence != sequence
            @horizontal_offset = 0 if @selected_sequence != sequence
            @inputs[sequence] = event["command"].as_s
            @selected_sequence = sequence
          when "select"
            if @inputs.has_key?(sequence) && @selected_sequence != sequence
              @selected_sequence = sequence
              @scroll_offset = 0
              @horizontal_offset = 0
            end
          when "output"
            chunk = event["chunk"].as_s
            previous = @outputs.fetch(sequence, "")
            updated = previous + chunk
            if sequence == @selected_sequence && @scroll_offset > 0 && !@statuses.has_key?(sequence)
              @scroll_offset += viewport_row_count(updated, @render_width) - viewport_row_count(previous, @render_width)
            end
            @outputs[sequence] = updated
          when "complete"
            @statuses[sequence] = event["status"].as_i64.to_i32
            if clean_output = event.as_h["clean_output"]?
              @clean_outputs[sequence] = clean_output.as_s
            end
          when "toggle_view"
            @raw_view = !@raw_view
          when "toggle_wrap"
            @wrap_lines = !@wrap_lines
            @horizontal_offset = 0
            @scroll_offset = 0
          when "toggle_list_view"
            @list_view = !@list_view
            @list_scroll_offset = 0
          when "scroll"
            if action = scroll_action(event["action"].as_s)
              scroll_current_view_locked(action)
            end
          end
        end
      end
    end
  
    @inputs = {} of UInt64 => String
    @outputs = {} of UInt64 => String
    @clean_outputs = {} of UInt64 => String
    @statuses = {} of UInt64 => Int32
    @selected_sequence : UInt64?
    @raw_view = false
    @list_view = false
    @wrap_lines = true
    @horizontal_offset = 0
    @render_width = 79
    @list_scroll_offset = 0
    @list_body_height = 1
    @list_scrollable_lines = 0
    @scroll_offset = 0
    @body_height = 1
    @scrollable_lines = 0
    @cached_terminal_height = 24
    @terminal_height_checked_at : Time::Instant?
    @mutex = Sync::Mutex.new
    
    def initialize
      @selected_sequence = nil
    end
    
    # Switch the completed-command display between PTY transcript and extracted output.
    def toggle_view : Bool
      @mutex.synchronize do
        @raw_view = !@raw_view
      end
    end
    
    # Switch between wrapped logical lines and one-row-per-line horizontal inspection.
    def toggle_wrap : Bool
      @mutex.synchronize do
        @wrap_lines = !@wrap_lines
        @horizontal_offset = 0
        @scroll_offset = 0
        @wrap_lines
      end
    end
    
    def wrap_lines? : Bool
      @mutex.synchronize { @wrap_lines }
    end
    
    # Return the complete output currently represented by the selected view.
    # Viewport scrolling and the available-outputs list do not truncate this value.
    def current_output : String?
      @mutex.synchronize do
        if sequence = @selected_sequence
          completed = @statuses.has_key?(sequence)
          displayed_output_for(sequence, completed)[0]
        end
      end
    end
    
    # Move the output viewport vertically or horizontally.
    def scroll(action : TmuxREPL::Keyboard::Action) : Bool
      @mutex.synchronize { scroll_current_view_locked(action) }
    end
    
    private def scroll_current_view_locked(action : TmuxREPL::Keyboard::Action) : Bool
      @list_view ? scroll_list_locked(action) : scroll_locked(action)
    end
    
    private def scroll_list_locked(action : TmuxREPL::Keyboard::Action) : Bool
      previous_offset = @list_scroll_offset
      page_step = @list_body_height - 1
      page_step = 1 if page_step < 1
    
      case action
      when TmuxREPL::Keyboard::Action::ScrollUp
        @list_scroll_offset += 1
      when TmuxREPL::Keyboard::Action::ScrollDown
        @list_scroll_offset -= 1
      when TmuxREPL::Keyboard::Action::ScrollPageUp
        @list_scroll_offset += page_step
      when TmuxREPL::Keyboard::Action::ScrollPageDown
        @list_scroll_offset -= page_step
      end
    
      max_offset = @list_scrollable_lines - @list_body_height
      max_offset = 0 if max_offset < 0
      @list_scroll_offset = 0 if @list_scroll_offset < 0
      @list_scroll_offset = max_offset if @list_scroll_offset > max_offset
    
      @list_scroll_offset != previous_offset
    end
    
    private def scroll_locked(action : TmuxREPL::Keyboard::Action) : Bool
      previous_offset = @scroll_offset
      previous_horizontal_offset = @horizontal_offset
      page_step = @body_height - 1
      page_step = 1 if page_step < 1
    
      case action
      when TmuxREPL::Keyboard::Action::ScrollUp
        @scroll_offset += 1
      when TmuxREPL::Keyboard::Action::ScrollDown
        @scroll_offset -= 1
      when TmuxREPL::Keyboard::Action::ScrollPageUp
        @scroll_offset += page_step
      when TmuxREPL::Keyboard::Action::ScrollPageDown
        @scroll_offset -= page_step
      when TmuxREPL::Keyboard::Action::ScrollHorizontalLeft
        @horizontal_offset -= 1 if !@wrap_lines && @horizontal_offset > 0
      when TmuxREPL::Keyboard::Action::ScrollHorizontalRight
        @horizontal_offset += 1 if !@wrap_lines && @horizontal_offset < maximum_horizontal_offset
      when TmuxREPL::Keyboard::Action::ScrollHorizontalStart
        @horizontal_offset = 0 unless @wrap_lines
      when TmuxREPL::Keyboard::Action::ScrollHorizontalEnd
        @horizontal_offset = maximum_horizontal_offset unless @wrap_lines
      end
    
      max_offset = @scrollable_lines - @body_height
      max_offset = 0 if max_offset < 0
      @scroll_offset = 0 if @scroll_offset < 0
      @scroll_offset = max_offset if @scroll_offset > max_offset
    
      @horizontal_offset = 0 if @wrap_lines
      @horizontal_offset = maximum_horizontal_offset if @horizontal_offset > maximum_horizontal_offset
    
      @scroll_offset != previous_offset || @horizontal_offset != previous_horizontal_offset
    end
    
    private def maximum_horizontal_offset : Int32
      return 0 if @wrap_lines
      return 0 unless sequence = @selected_sequence
    
      completed = @statuses.has_key?(sequence)
      displayed_output, _label = displayed_output_for(sequence, completed)
      return 0 unless output = displayed_output
    
      widest_line = output_lines(output).max_of? { |line| display_width(line) } || 0
      visible_width = @render_width - 1
      visible_width = 0 if visible_width < 0
      offset = widest_line - visible_width
      offset > 0 ? offset : 0
    end
    
    private def scroll_action(name : String) : TmuxREPL::Keyboard::Action?
      case name
      when "ScrollUp"                   then TmuxREPL::Keyboard::Action::ScrollUp
      when "ScrollDown"                 then TmuxREPL::Keyboard::Action::ScrollDown
      when "ScrollPageUp"               then TmuxREPL::Keyboard::Action::ScrollPageUp
      when "ScrollPageDown"             then TmuxREPL::Keyboard::Action::ScrollPageDown
      when "ScrollHorizontalLeft"       then TmuxREPL::Keyboard::Action::ScrollHorizontalLeft
      when "ScrollHorizontalRight"      then TmuxREPL::Keyboard::Action::ScrollHorizontalRight
      when "ScrollHorizontalStart"      then TmuxREPL::Keyboard::Action::ScrollHorizontalStart
      when "ScrollHorizontalEnd"        then TmuxREPL::Keyboard::Action::ScrollHorizontalEnd
      end
    end
    
    private def output_lines(text : String) : Array(String)
      normalized = text.gsub("\r\n", "\n").gsub("\r", "\n")
      return [] of String if normalized.empty?
    
      lines = normalized.split('\n', remove_empty: false)
      lines.pop if normalized.ends_with?('\n')
      lines
    end
    
    private def terminal_height : Int32
      if checked_at = @terminal_height_checked_at
        return @cached_terminal_height if Time.instant - checked_at < 250.milliseconds
      end
    
      @terminal_height_checked_at = Time.instant
      @cached_terminal_height = Tmux::Pane.from_env.height
    rescue
      @cached_terminal_height = ENV["LINES"]?.try(&.to_i?) || 24
    end
    
    include Update
    include Render
  end

  class X11Clipboard
    getter xclip_path : String
    
    def initialize(@xclip_path : String = ENV["TMUX_REPL_XCLIP"]? || "xclip")
    end
    
    # Copy the same complete text to both X11 selections, matching Neovim's + and * registers.
    def copy(text : String) : Nil
      {"clipboard", "primary"}.each do |selection|
        status = Process.run(
          @xclip_path,
          ["-selection", selection, "-i"],
          input: IO::Memory.new(text),
          output: Process::Redirect::Close
        )
    
        unless status.success?
          raise "xclip exited with status #{status.exit_code} for the #{selection} selection"
        end
      end
    end
  end
end