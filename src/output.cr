require "json"
require "sync/mutex"
require "./tmux_repl"

module Output
  # Output-pane process implementation and rendering.

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
      
          view.update(data)
      
          render_started_at = Time.instant if TmuxREPL.trace_timing_enabled?
          view.render
          if render_started = render_started_at
            TmuxREPL.trace_timing(
              @session_name, "output", "event_rendered", render_started,
              "type=#{event_type} sequence=#{sequence}"
            )
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
    end
  
    module Helpers
      private def state_dir : String
        base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
        File.join(base, "tmux-repl", @session_name)
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
            view.render if view.scroll(action)
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
    
    def initialize(@session_name : String)
    end
    
    include Helpers
    include Consume
    include Keyboard
    include Run
  end

  class View
    module Render
      # Draw a fixed header and status around a scrollable output viewport.
      def render(io : IO = STDOUT, height : Int32? = nil) : Nil
        @mutex.synchronize do
          screen_height = height || terminal_height
          screen_height = 1 if screen_height < 1
      
          unless selected = @selected_sequence
            render_frame(io, ["No inputs yet."], screen_height)
            next
          end
      
          command = @inputs[selected]?
          unless command
            render_frame(io, ["Waiting for input ##{selected}..."], screen_height)
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
      
          # Keep the footer visible even when a long command leaves little room for output.
          footer = footer.last(screen_height)
          header_limit = screen_height - footer.size - 1
          header = header.first(header_limit) if header.size > header_limit
          @body_height = screen_height - header.size - footer.size
          @scrollable_lines = body.size
      
          max_offset = @scrollable_lines - @body_height
          max_offset = 0 if max_offset < 0
          @scroll_offset = 0 if @scroll_offset < 0
          @scroll_offset = max_offset if @scroll_offset > max_offset
      
          visible_end = @scrollable_lines - @scroll_offset
          visible_start = visible_end - @body_height
          visible_start = 0 if visible_start < 0
      
          frame = header.dup
          index = visible_start
          while index < visible_end
            frame << body[index]
            index += 1
          end
          frame.concat(footer)
          render_frame(io, frame, screen_height)
        end
      end
      
      # Rewrite each row in place. Clearing to end-of-line removes remnants of longer
      # previous rows without blanking the whole pane between frames.
      private def render_frame(io : IO, lines : Array(String), height : Int32) : Nil
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
      
    end
  
    module Update
      # Apply one event from the session event stream to the displayed view.
      def update(event : JSON::Any) : Nil
        @mutex.synchronize do
          sequence = event["sequence"].as_i64.to_u64
      
          case event["type"].as_s
          when "input"
            @scroll_offset = 0 if @selected_sequence != sequence
            @inputs[sequence] = event["command"].as_s
            @selected_sequence = sequence
          when "select"
            if @inputs.has_key?(sequence) && @selected_sequence != sequence
              @selected_sequence = sequence
              @scroll_offset = 0
            end
          when "output"
            chunk = event["chunk"].as_s
            previous = @outputs.fetch(sequence, "")
            updated = previous + chunk
            if sequence == @selected_sequence && @scroll_offset > 0 && !@statuses.has_key?(sequence)
              @scroll_offset += output_lines(updated).size - output_lines(previous).size
            end
            @outputs[sequence] = updated
          when "complete"
            @statuses[sequence] = event["status"].as_i64.to_i32
            if clean_output = event.as_h["clean_output"]?
              @clean_outputs[sequence] = clean_output.as_s
            end
          when "toggle_view"
            @raw_view = !@raw_view
          when "scroll"
            if action = scroll_action(event["action"].as_s)
              scroll_locked(action)
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
    
    # Move the output viewport without moving the pinned command header or status.
    def scroll(action : TmuxREPL::Keyboard::Action) : Bool
      @mutex.synchronize { scroll_locked(action) }
    end
    
    private def scroll_locked(action : TmuxREPL::Keyboard::Action) : Bool
      previous_offset = @scroll_offset
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
      end
    
      max_offset = @scrollable_lines - @body_height
      max_offset = 0 if max_offset < 0
      @scroll_offset = 0 if @scroll_offset < 0
      @scroll_offset = max_offset if @scroll_offset > max_offset
    
      @scroll_offset != previous_offset
    end
    
    private def scroll_action(name : String) : TmuxREPL::Keyboard::Action?
      case name
      when "ScrollUp"       then TmuxREPL::Keyboard::Action::ScrollUp
      when "ScrollDown"     then TmuxREPL::Keyboard::Action::ScrollDown
      when "ScrollPageUp"   then TmuxREPL::Keyboard::Action::ScrollPageUp
      when "ScrollPageDown" then TmuxREPL::Keyboard::Action::ScrollPageDown
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
end