require "reply"
require "./tmux_repl"

module Input

  class Reader < Reply::Reader
    module ReadNext
      # Reply may batch ordinary text with the Enter byte; keep Enter parseable.
      def read_next(from io : IO = STDIN) : String?
        super(from: @keyboard_io)
      end
      
      # Enqueue all ordinary characters; bound shortcuts are consumed by the dispatcher.
      private def on_char(char : Char) : Nil
        super unless TmuxREPL::Keyboard.binding_for(char)
      end
      
      # Reply may return a batch of characters when several arrive in one read.
      private def on_string(string : String) : Nil
        editable = String.build do |io|
          string.each_char do |char|
            io << char unless TmuxREPL::Keyboard.binding_for(char)
          end
        end
        super(editable) unless editable.empty?
      end
    end
  
    @ready_path : String
    @keyboard : TmuxREPL::Keyboard::Dispatcher
    @keyboard_io : TmuxREPL::Keyboard::InputIO(IO::FileDescriptor)
    @on_previous : Proc(Nil)?
    @on_next : Proc(Nil)?
    
    def initialize(
      @ready_path : String,
      @keyboard : TmuxREPL::Keyboard::Dispatcher,
      @on_previous : Proc(Nil)? = nil,
      @on_next : Proc(Nil)? = nil
    )
      @keyboard_io = TmuxREPL::Keyboard::InputIO.new(STDIN, @keyboard)
      super()
    end
    
    include ReadNext
    
    private def on_ctrl_up(& : String ->) : Nil
      binding = @keyboard_io.take_navigation_binding(TmuxREPL::Keyboard::Action::SelectPrevious)
      if callback = @on_previous
        callback.call
        @keyboard.enqueue(
          binding || TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Up").not_nil!
        )
      else
        @editor.scroll_down
      end
    end
    
    private def on_ctrl_down(& : String ->) : Nil
      binding = @keyboard_io.take_navigation_binding(TmuxREPL::Keyboard::Action::SelectNext)
      if callback = @on_next
        callback.call
        @keyboard.enqueue(
          binding || TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Down").not_nil!
        )
      else
        @editor.scroll_up
      end
    end
    
    def prompt(io : IO, line_number : Int32, color : Bool)
      super(io, line_number, color)
      File.write(@ready_path, Process.pid.to_s) unless File.exists?(@ready_path)
    end
  end

  class Runner
    module Controls
      # Handle input-pane commands without submitting them to the worker.
      private def handle_control(
        control : String,
        events : AMQP::Client::Queue,
        history : TmuxREPL::InputHistory
      ) : Bool
        if match = control.match(/\A:select\s+([0-9]+)\z/)
          target = match[1].to_u64
          if history.includes?(target)
            select_input(target, events, history)
          else
            puts "No input ##{target}. Use :list to see submitted inputs."
          end
          return true
        end
      
        case control
        when ":prev"
          if target = history.previous_sequence
            select_input(target, events, history)
          elsif history.selected_sequence
            puts "Already at the oldest input."
          else
            puts "No inputs have been submitted."
          end
          true
        when ":next"
          if target = history.next_sequence
            select_input(target, events, history)
          elsif history.selected_sequence
            puts "Already at the newest input."
          else
            puts "No inputs have been submitted."
          end
          true
        when ":list"
          if history.entries.empty?
            puts "No inputs have been submitted."
          else
            history.entries.each do |entry|
              marker = entry[0] == history.selected_sequence ? "*" : " "
              puts "#{marker} ##{entry[0]}: #{entry[1].lines.first? || entry[1]}"
            end
          end
          true
        when ":help"
          puts ":select ID  Show the output associated with an input."
          puts ":prev       Select the previous input."
          puts ":next       Select the next input."
          puts ":list       List submitted inputs."
          puts TmuxREPL::Keyboard.help_text
          true
        else
          false
        end
      end
      
      private def select_input(
        sequence_number : UInt64,
        events : AMQP::Client::Queue,
        history : TmuxREPL::InputHistory
      ) : Nil
        TmuxREPL.publish_event(events, "select", @session_name, sequence_number)
        history.select(sequence_number)
      end
    end
  
    module Helpers
      private def state_dir : String
        @state.base_path
      end
      
      private def input_pid_path : String
        File.join(state_dir, "input.pid")
      end
      
      private def startup_error_path : String
        File.join(state_dir, "input.error")
      end
      
      private def startup_stage_path : String
        File.join(state_dir, "input.startup")
      end
      
      private def prepare_startup : Nil
        File.delete(startup_error_path) if File.exists?(startup_error_path)
        update_startup_stage("connecting to LavinMQ")
      end
      
      private def update_startup_stage(stage : String) : Nil
        File.write(startup_stage_path, stage)
      end
      
      private def report_startup_failure(exception : Exception) : Nil
        File.write(startup_error_path, "#{exception.class}: #{exception.message}")
        STDERR.puts "tmux.repl.input: #{exception.class}: #{exception.message}"
      end
      
      private def cleanup_readiness : Nil
        File.delete(input_pid_path) if File.exists?(input_pid_path)
      end
    end
  
    module Run
      # Connect to the streams, then read and dispatch user input.
      def run : Nil
        prepare_startup
        keyboard : TmuxREPL::Keyboard::Dispatcher? = nil
        terminal_mode = TmuxREPL::TerminalMode.new
      
        begin
          channel = Global.amqp_channel
      
          update_startup_stage("declaring command stream")
          commands = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(@session_name))
      
          update_startup_stage("declaring event stream")
          events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(@session_name))
      
          update_startup_stage("starting keyboard dispatcher")
          keyboard = TmuxREPL::Keyboard::Dispatcher.new(@session_name, "input", events)
          keyboard.start
      
          update_startup_stage("initializing Reply reader")
          history = TmuxREPL::InputHistory.new
          on_previous = -> { handle_control(":prev", events, history); nil }
          on_next = -> { handle_control(":next", events, history); nil }
          reader = Reader.new(input_pid_path, keyboard, on_previous, on_next)
          File.delete(startup_stage_path) if File.exists?(startup_stage_path)
      
          terminal_mode.enable
          reader.read_loop do |expression|
            next if expression.strip.empty?
            next if handle_control(expression.strip, events, history)
      
            submit(expression, events, commands, history)
          end
        rescue ex
          report_startup_failure(ex)
          exit 1
        ensure
          begin
            keyboard.try &.stop
            terminal_mode.restore
          ensure
            cleanup_readiness
          end
        end
      end
    end
  
    module Submit
      # Publish the input event before sending the command to the worker.
      private def submit(
        expression : String,
        events : AMQP::Client::Queue,
        commands : AMQP::Client::Queue,
        history : TmuxREPL::InputHistory
      ) : Nil
        sequence = history.add(expression)
        command_received_at = Time.instant
        TmuxREPL.trace_timing(
          @session_name, "input", "command_received",
          details: "sequence=#{sequence} command_bytes=#{expression.bytesize}"
        )
      
        input_event_started_at = Time.instant if TmuxREPL.trace_timing_enabled?
        TmuxREPL.publish_event(events, "input", @session_name, sequence, command: expression)
        if publish_started = input_event_started_at
          TmuxREPL.trace_timing(
            @session_name, "input", "input_event_confirmed", publish_started,
            "sequence=#{sequence}"
          )
        end
      
        command_publish_started_at = Time.instant if TmuxREPL.trace_timing_enabled?
        TmuxREPL.publish_command(commands, @session_name, sequence, expression)
        if publish_started = command_publish_started_at
          TmuxREPL.trace_timing(
            @session_name, "input", "command_publish_confirmed", publish_started,
            "sequence=#{sequence}"
          )
        end
      
        TmuxREPL.trace_timing(
          @session_name, "input", "submission_published", command_received_at,
          "sequence=#{sequence}"
        )
        puts "[input ##{sequence}] submitted. Use :select ID, :prev, :next, :list, or :help."
      end
    end
  
    getter session_name : String
    
    def initialize(@session_name : String)
      @state = TmuxREPL::State.open(@session_name)
    end
    
    include Helpers
    include Controls
    include Submit
    include Run
  end
end