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
          begin
            while key = STDIN.read_char
              dispatcher.enqueue(key)
            end
          rescue IO::Error
            # The pane may close while the keyboard reader is waiting.
          ensure
            terminal_mode.restore
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
      
          dispatcher = TmuxREPL::Keyboard::Dispatcher.new(@session_name, "output", queue)
          dispatcher.start
      
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
      
          toggle_key = TmuxREPL::Keyboard.label_for(TmuxREPL::Keyboard::Action::ToggleOutputView)
          io.puts "INPUT ##{selected} [#{mode_label}; #{toggle_key} toggles view]"
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
    end
  
    module Update
      # Apply one event from the session event stream to the displayed view.
      def update(event : JSON::Any) : Nil
        @mutex.synchronize do
          sequence = event["sequence"].as_i64.to_u64
      
          case event["type"].as_s
          when "input"
            @inputs[sequence] = event["command"].as_s
            @selected_sequence = sequence
          when "select"
            @selected_sequence = sequence if @inputs.has_key?(sequence)
          when "output"
            chunk = event["chunk"].as_s
            @outputs[sequence] = @outputs.fetch(sequence, "") + chunk
          when "complete"
            @statuses[sequence] = event["status"].as_i64.to_i32
            if clean_output = event.as_h["clean_output"]?
              @clean_outputs[sequence] = clean_output.as_s
            end
          when "toggle_view"
            @raw_view = !@raw_view
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
    
    include Update
    include Render
  end
end