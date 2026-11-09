require "file_utils"
require "yaml"
require "digest/sha256"
require "json"
require "tmux"
require "global-amqp_channel"
require "queue"
require "./custom_repl"

module TmuxREPL
  module Publishing
    def publish_message(
      queue : AMQP::Client::Queue,
      type : String,
      session_name : String,
      sequence : UInt64,
      command : String? = nil,
      chunk : String? = nil,
      status : Int32? = nil,
      clean_output : String? = nil,
      action : String? = nil,
      requesting_pane : String? = nil
    ) : Nil
      payload = JSON.build do |json|
        json.object do
          json.field "type", type
          json.field "session", session_name
          json.field "sequence", sequence
          json.field "timestamp", Time.utc.to_s
          json.field "command", command if command
          json.field "chunk", chunk if chunk
          json.field "status", status if status
          json.field "clean_output", clean_output if clean_output
          json.field "action", action if action
          json.field "requesting_pane", requesting_pane if requesting_pane
        end
      end
      properties = AMQP::Client::Properties.new(delivery_mode: 2)
      raise "LavinMQ did not confirm publish to stream #{queue.name}" unless queue.publish_confirm(payload, props: properties)
    end
    
    def publish_event(
      queue : AMQP::Client::Queue,
      type : String,
      session_name : String,
      sequence : UInt64,
      command : String? = nil,
      chunk : String? = nil,
      status : Int32? = nil,
      clean_output : String? = nil,
      action : String? = nil,
      requesting_pane : String? = nil
    ) : Nil
      publish_message(queue, type, session_name, sequence, command, chunk, status, clean_output, action, requesting_pane)
    end
    
    def publish_command(
      queue : AMQP::Client::Queue,
      session_name : String,
      sequence : UInt64,
      command : String
    ) : Nil
      publish_message(queue, "command", session_name, sequence, command: command)
    end
  end

  module TraceTiming
    # Optional timing diagnostics for tracing command latency across the separate
    # input, worker, and output processes. Disabled unless explicitly requested.
    def trace_timing_enabled? : Bool
      ENV["TMUX_REPL_TRACE_TIMING"]? == "1"
    end
    
    def trace_timing(
      session_name : String,
      component : String,
      event : String,
      started_at : Time::Instant? = nil,
      details : String = ""
    ) : Nil
      return unless trace_timing_enabled?
    
      trace_path = ENV["TMUX_REPL_TRACE_FILE"]? || State.open(session_name).log_path("timing.log")
    
      elapsed = if start = started_at
        " elapsed_ms=#{(Time.instant - start).total_milliseconds.round(2)}"
      else
        ""
      end
      detail_suffix = details.empty? ? "" : " #{details}"
    
      File.open(trace_path, "a") do |file|
        file.puts "#{Time.utc} [#{component}] #{event}#{elapsed}#{detail_suffix}"
      end
    rescue
      # Diagnostic tracing must never interfere with REPL command execution.
    end
  end

  def self.define(name : String, &configure : Definition ->) : Definition
    definition = Definition.new(name)
    yield definition
    definition
  end
  
  def self.component_name(session_name : String) : String
    component = session_name.gsub(/[^a-zA-Z0-9._-]/, "_")
    component = "session" if component.empty?
    component[0, 220]
  end
  
  def self.commands_queue_name(session_name : String) : String
    "tmux.repl.#{component_name(session_name)}.commands"
  end
  
  def self.events_queue_name(session_name : String) : String
    "tmux.repl.#{component_name(session_name)}.events"
  end
  
  def self.stream_queue(channel : AMQP::Client::Channel, name : String) : AMQP::Client::Queue
    channel.queue(name, args: AMQP::Client::Arguments.new({"x-queue-type": "stream"}))
  end
  
  extend Publishing
  extend TraceTiming

  class Definition
    getter name : String
    
    @command : Array(String)?
    @environment : Hash(String, String)
    @start_directory : String?
    @input_executable : String?
    @output_executable : String?
    @worker_executable : String?
    @handlers : Hash(String, Proc(CustomREPL::CommandContext, Array(String), Nil))
    @host : CustomREPL::CustomCommandHost?
    
    def initialize(@name : String)
      @command = nil
      @environment = {} of String => String
      @start_directory = nil
      @input_executable = nil
      @output_executable = nil
      @worker_executable = nil
      @handlers = {} of String => Proc(CustomREPL::CommandContext, Array(String), Nil)
      @host = nil
    end
    
    # Configure a native interactive program for this REPL.
    # With no command or custom handlers, the standard shell/PTY worker is used.
    def command(*arguments : String) : self
      configure_command(arguments.to_a)
    end
    
    def command(arguments : Array(String)) : self
      configure_command(arguments)
    end
    
    # Register an application command. Handlers run in the process that owns this
    # Definition, not in the separate PTY worker.
    def on_command(
      name : String,
      &handler : CustomREPL::CommandContext, Array(String) -> Nil
    ) : self
      raise ArgumentError.new("Cannot register custom commands with a native REPL command") if @command
      unless name.match(/\A[a-zA-Z][a-zA-Z0-9_-]*\z/)
        raise ArgumentError.new("Invalid custom command name: #{name.inspect}")
      end
      raise ArgumentError.new("Custom command #{name.inspect} is already registered") if @handlers.has_key?(name)
    
      @handlers[name] = handler
      self
    end
    
    def command_names : Array(String)
      @handlers.keys.sort
    end
    
    def custom_commands? : Bool
      !@handlers.empty?
    end
    
    def env(name : String, value : String) : self
      @environment[name] = value
      self
    end
    
    def env(values : Hash(String, String)) : self
      @environment.merge!(values)
      self
    end
    
    def cwd(path : String) : self
      @start_directory = path
      self
    end
    
    # Override any of the companion processes independently. Unspecified
    # executables continue to use the normal sibling/PATH discovery.
    def executables(
      input : String? = nil,
      output : String? = nil,
      worker : String? = nil
    ) : self
      @input_executable = input unless input.nil?
      @output_executable = output unless output.nil?
      @worker_executable = worker unless worker.nil?
      self
    end
    
    def session : Session
      raise ArgumentError.new("A REPL cannot combine a native command with custom handlers") if @command && custom_commands?
    
      Session.new(
        @name,
        command: @command,
        environment: @environment,
        start_directory: @start_directory,
        input_executable: @input_executable,
        output_executable: @output_executable,
        worker_executable: @worker_executable,
        custom_command_mode: custom_commands?
      )
    end
    
    def start(focus : Bool = true) : Session
      raise "Custom REPL is already started" if @host
    
      repl_session = session
      if custom_commands?
        @host = CustomREPL::CustomCommandHost.new(@name, repl_session.state.base_path, @handlers.dup)
        @host.not_nil!.start
      end
    
      repl_session.start(focus)
      repl_session
    rescue ex
      @host.try &.stop
      @host = nil
      raise ex
    end
    
    # Block the application process while the custom REPL session is alive.
    # The command consumer is connected by start before the input pane is exposed.
    def serve : Nil
      host = @host || raise "No custom command host is active; register commands and call start first."
      begin
        host.wait
      ensure
        @host = nil
      end
    end
    
    def stop : Nil
      @host.try &.stop
      session.stop
    end
    
    private def configure_command(arguments : Array(String)) : self
      raise ArgumentError.new("REPL command must not be empty") if arguments.empty?
      raise ArgumentError.new("Cannot configure a native command after registering custom handlers") if custom_commands?
    
      @command = arguments.dup
      self
    end
  end

  class InputHistory
    getter entries : Array(Tuple(UInt64, String))
    getter selected_sequence : UInt64?
    
    @sequence = 0_u64
    @entries = [] of Tuple(UInt64, String)
    @selected_sequence : UInt64?
    
    def initialize
      @selected_sequence = nil
    end
    
    def add(expression : String) : UInt64
      @sequence &+= 1_u64
      @entries << {@sequence, expression}
      @selected_sequence = @sequence
      @sequence
    end
    
    def includes?(sequence : UInt64) : Bool
      @entries.any? { |entry| entry[0] == sequence }
    end
    
    def select(sequence : UInt64) : Bool
      return false unless includes?(sequence)
    
      @selected_sequence = sequence
      true
    end
    
    def previous_sequence : UInt64?
      adjacent_sequence(-1)
    end
    
    def next_sequence : UInt64?
      adjacent_sequence(1)
    end
    
    private def adjacent_sequence(direction : Int32) : UInt64?
      selected = @selected_sequence
      return unless selected
    
      index = @entries.index { |entry| entry[0] == selected }
      return unless index
    
      target_index = index + direction
      return if target_index < 0 || target_index >= @entries.size
    
      @entries[target_index][0]
    end
  end

  module Keyboard
    enum Action
      ToggleOutputView
      ToggleOutputList
      ToggleOutputWrap
      ToggleOutputZoom
      SelectPrevious
      SelectNext
      SubmitInput
      ScrollUp
      ScrollDown
      ScrollPageUp
      ScrollPageDown
      ScrollHorizontalLeft
      ScrollHorizontalRight
      ScrollHorizontalStart
      ScrollHorizontalEnd
    end
    
    struct Binding
      getter key : Char
      getter action : Action
      getter label : String
      getter description : String
    
      def initialize(@key : Char, @action : Action, @label : String, @description : String)
      end
    
      def help_line : String
        "#{label.ljust(16)}#{description}"
      end
    end
    
    struct SequenceBinding
      getter key : String
      getter action : Action
      getter label : String
      getter description : String
    
      def initialize(@key : String, @action : Action, @label : String, @description : String)
      end
    
      def help_line : String
        "#{label.ljust(16)}#{description}"
      end
    end
    
    BINDINGS = [
      Binding.new(
        '\u0007',
        Action::ToggleOutputView,
        "Ctrl+G",
        "Toggle stripped/raw output from either pane."
      ),
      Binding.new(
        '\u000c',
        Action::ToggleOutputList,
        "Ctrl+L",
        "Toggle the available-outputs list from either pane."
      ),
      Binding.new(
        '\u0017',
        Action::ToggleOutputWrap,
        "Ctrl+W",
        "Toggle wrapped/unwrapped output from either pane."
      ),
    ]
    
    # Ctrl+Up/Down are the primary input-selection bindings. Alt+K/J are aliases.
    SEQUENCE_BINDINGS = [
      SequenceBinding.new("Ctrl+Up", Action::SelectPrevious, "Ctrl+Up", "Select the previous input."),
      SequenceBinding.new("Ctrl+Down", Action::SelectNext, "Ctrl+Down", "Select the next input."),
      SequenceBinding.new("Alt+K", Action::SelectPrevious, "Alt+K", "Also select the previous input."),
      SequenceBinding.new("Alt+J", Action::SelectNext, "Alt+J", "Also select the next input."),
      SequenceBinding.new("Alt+Up", Action::ScrollUp, "Alt+Up", "Scroll output up one line from either pane."),
      SequenceBinding.new("Alt+Down", Action::ScrollDown, "Alt+Down", "Scroll output down one line from either pane."),
      SequenceBinding.new("Alt+PageUp", Action::ScrollPageUp, "Alt+PageUp", "Scroll output up one page from either pane."),
      SequenceBinding.new("Alt+PageDown", Action::ScrollPageDown, "Alt+PageDown", "Scroll output down one page from either pane."),
      SequenceBinding.new("Alt+Left", Action::ScrollHorizontalLeft, "Alt+Left", "Scroll an unwrapped line left."),
      SequenceBinding.new("Alt+Right", Action::ScrollHorizontalRight, "Alt+Right", "Scroll an unwrapped line right."),
      SequenceBinding.new("Alt+Home", Action::ScrollHorizontalStart, "Alt+Home", "Jump to the start of an unwrapped line."),
      SequenceBinding.new("Alt+End", Action::ScrollHorizontalEnd, "Alt+End", "Jump to the end of an unwrapped line."),
      SequenceBinding.new("Alt+Z", Action::ToggleOutputZoom, "Alt+Z", "Zoom or restore the Output pane from either pane."),
    ]
    
    # xterm modifier parameter 3 represents Alt combined with the key.
    INPUT_ACTION_SEQUENCES = {
      "\ez"       => "Alt+Z",
      "\e[122;3u" => "Alt+Z",
      "\e[1;3A" => "Alt+Up",
      "\e[1;3B" => "Alt+Down",
      "\e[5;3~" => "Alt+PageUp",
      "\e[6;3~" => "Alt+PageDown",
      "\e[1;3D" => "Alt+Left",
      "\e[1;3C" => "Alt+Right",
      "\e[1;3H" => "Alt+Home",
      "\e[1;3F" => "Alt+End",
      "\e\e[A"  => "Alt+Up",
      "\e\e[B"  => "Alt+Down",
      "\e\e[5~" => "Alt+PageUp",
      "\e\e[6~" => "Alt+PageDown",
      "\e\e[D"  => "Alt+Left",
      "\e\e[C"  => "Alt+Right",
      "\e\e[H"  => "Alt+Home",
      "\e\e[F"  => "Alt+End",
    }
    
    INPUT_SEQUENCE_STRINGS = [
      "\ez", "\e[122;3u",
      "\ek", "\ej", "\e[107;3u", "\e[106;3u",
      "\e[1;5A", "\e[1;5B",
      "\e[1;3A", "\e[1;3B", "\e[5;3~", "\e[6;3~",
      "\e[1;3D", "\e[1;3C", "\e[1;3H", "\e[1;3F",
      "\e\e[A", "\e\e[B", "\e\e[5~", "\e\e[6~",
      "\e\e[D", "\e\e[C", "\e\e[H", "\e\e[F",
    ]
    
    # Unmodified keys and their Alt-modified equivalents are accepted in Output.
    OUTPUT_SEQUENCE_BINDINGS = {
      "\ez"       => SequenceBinding.new("Alt+Z", Action::ToggleOutputZoom, "Alt+Z", "Zoom or restore the Output pane."),
      "\e[122;3u" => SequenceBinding.new("Alt+Z", Action::ToggleOutputZoom, "Alt+Z", "Zoom or restore the Output pane."),
      "\e[A"    => SequenceBinding.new("Up", Action::ScrollUp, "Up", "Scroll output up one line."),
      "\e[B"    => SequenceBinding.new("Down", Action::ScrollDown, "Down", "Scroll output down one line."),
      "\e[5~"   => SequenceBinding.new("PageUp", Action::ScrollPageUp, "PageUp", "Scroll output up one page."),
      "\e[6~"   => SequenceBinding.new("PageDown", Action::ScrollPageDown, "PageDown", "Scroll output down one page."),
      "\e[D"    => SequenceBinding.new("Left", Action::ScrollHorizontalLeft, "Left", "Scroll an unwrapped output line left."),
      "\e[C"    => SequenceBinding.new("Right", Action::ScrollHorizontalRight, "Right", "Scroll an unwrapped output line right."),
      "\e[H"    => SequenceBinding.new("Home", Action::ScrollHorizontalStart, "Home", "Jump to the start of an unwrapped line."),
      "\e[F"    => SequenceBinding.new("End", Action::ScrollHorizontalEnd, "End", "Jump to the end of an unwrapped line."),
      "\e[1;3A" => SequenceBinding.new("Alt+Up", Action::ScrollUp, "Alt+Up", "Scroll output up one line."),
      "\e[1;3B" => SequenceBinding.new("Alt+Down", Action::ScrollDown, "Alt+Down", "Scroll output down one line."),
      "\e[5;3~" => SequenceBinding.new("Alt+PageUp", Action::ScrollPageUp, "Alt+PageUp", "Scroll output up one page."),
      "\e[6;3~" => SequenceBinding.new("Alt+PageDown", Action::ScrollPageDown, "Alt+PageDown", "Scroll output down one page."),
      "\e[1;3D" => SequenceBinding.new("Alt+Left", Action::ScrollHorizontalLeft, "Alt+Left", "Scroll an unwrapped output line left."),
      "\e[1;3C" => SequenceBinding.new("Alt+Right", Action::ScrollHorizontalRight, "Alt+Right", "Scroll an unwrapped output line right."),
      "\e[1;3H" => SequenceBinding.new("Alt+Home", Action::ScrollHorizontalStart, "Alt+Home", "Jump to the start of an unwrapped line."),
      "\e[1;3F" => SequenceBinding.new("Alt+End", Action::ScrollHorizontalEnd, "Alt+End", "Jump to the end of an unwrapped line."),
      "\e\e[A"  => SequenceBinding.new("Alt+Up", Action::ScrollUp, "Alt+Up", "Scroll output up one line."),
      "\e\e[B"  => SequenceBinding.new("Alt+Down", Action::ScrollDown, "Alt+Down", "Scroll output down one line."),
      "\e\e[5~" => SequenceBinding.new("Alt+PageUp", Action::ScrollPageUp, "Alt+PageUp", "Scroll output up one page."),
      "\e\e[6~" => SequenceBinding.new("Alt+PageDown", Action::ScrollPageDown, "Alt+PageDown", "Scroll output down one page."),
      "\e\e[D"  => SequenceBinding.new("Alt+Left", Action::ScrollHorizontalLeft, "Alt+Left", "Scroll an unwrapped output line left."),
      "\e\e[C"  => SequenceBinding.new("Alt+Right", Action::ScrollHorizontalRight, "Alt+Right", "Scroll an unwrapped output line right."),
      "\e\e[H"  => SequenceBinding.new("Alt+Home", Action::ScrollHorizontalStart, "Alt+Home", "Jump to the start of an unwrapped line."),
      "\e\e[F"  => SequenceBinding.new("Alt+End", Action::ScrollHorizontalEnd, "Alt+End", "Jump to the end of an unwrapped line."),
    }
    
    def self.binding_for(key : Char) : Binding?
      BINDINGS.find { |binding| binding.key == key }
    end
    
    def self.sequence_binding_for(key : String) : SequenceBinding?
      SEQUENCE_BINDINGS.find { |binding| binding.key == key }
    end
    
    def self.output_sequence_binding_for(sequence : String) : SequenceBinding?
      OUTPUT_SEQUENCE_BINDINGS[sequence]?
    end
    
    def self.output_sequence_match(input : String) : Tuple(String, SequenceBinding)?
      OUTPUT_SEQUENCE_BINDINGS.each do |sequence, binding|
        return {sequence, binding} if input.starts_with?(sequence)
      end
    end
    
    def self.output_sequence_prefix?(input : String) : Bool
      OUTPUT_SEQUENCE_BINDINGS.keys.any? { |sequence| sequence.starts_with?(input) }
    end
    
    def self.action_for(key : Char) : Action?
      if binding = binding_for(key)
        binding.action
      end
    end
    
    def self.label_for(action : Action) : String
      BINDINGS.each do |binding|
        return binding.label if binding.action == action
      end
      SEQUENCE_BINDINGS.each do |binding|
        return binding.label if binding.action == action
      end
      raise ArgumentError.new("No keyboard binding registered for #{action}")
    end
    
    def self.help_text : String
      toggle_help = "Ctrl+G raw · Ctrl+L list · Ctrl+W wrap · Alt+Z zoom Output"
      horizontal_help = "Alt+←/→ scroll · Alt+Home/End jump"
      bindings = BINDINGS.reject do |binding|
        binding.action == Action::ToggleOutputView || binding.action == Action::ToggleOutputList || binding.action == Action::ToggleOutputWrap
      end
      horizontal_bindings = SEQUENCE_BINDINGS.reject do |binding|
        binding.action == Action::ScrollHorizontalLeft ||
          binding.action == Action::ScrollHorizontalRight ||
          binding.action == Action::ScrollHorizontalStart ||
          binding.action == Action::ScrollHorizontalEnd ||
          binding.action == Action::ToggleOutputZoom
      end
    
      ([toggle_help, horizontal_help] + bindings.map(&.help_line) + horizontal_bindings.map(&.help_line)).join("\n")
    end
  
    class InputIO(T) < IO
      @source_buffer = Bytes.new(8192)
      @read_buffer = Bytes.new(8192 * 3)
      @pending_source = [] of UInt8
      @source_size = 0
      @source_offset = 0
      @navigation_bindings = [] of SequenceBinding
      @eof = false
      
      def initialize(
        @source : T,
        @keyboard : Dispatcher? = nil
      )
      end
      
      def read(slice : Bytes) : Int32
        return 0 if slice.empty?
      
        refill if @source_offset >= @source_size && !@eof
        return 0 if @source_offset >= @source_size
      
        available = @source_size - @source_offset
        count = bytes_before_line_ending(available)
        count = Math.min(count, slice.size)
      
        slice[0, count].copy_from(@read_buffer[@source_offset, count])
        @source_offset += count
        if keyboard = @keyboard
          String.new(slice[0, count]).each_char { |char| keyboard.enqueue(char) }
        end
        count
      end
      
      # Reply reports native Ctrl arrows and translated Alt+K/J through its existing
      # callbacks. Preserve the original binding so the dispatcher can trace the key.
      def take_navigation_binding(action : Action) : SequenceBinding?
        return if @navigation_bindings.empty?
      
        binding = @navigation_bindings.first
        return unless binding.action == action
      
        @navigation_bindings.shift
      end
      
      def write(slice : Bytes) : Nil
        raise IO::Error.new("Keyboard input IO is read-only")
      end
      
      def tty? : Bool
        {% if T.has_method?(:tty?) %}
          @source.tty?
        {% else %}
          false
        {% end %}
      end
      
      def raw(& : self -> _)
        {% if T.has_method?(:raw) %}
          if @source.tty?
            @source.raw { yield self }
          else
            yield self
          end
        {% else %}
          yield self
        {% end %}
      end
      
      # Read until a complete input sequence or ordinary characters are available.
      # A trailing escape-sequence prefix is retained for the next OS read.
      private def refill : Nil
        loop do
          raw_size = @source.read(@source_buffer)
          raw_size.times { |index| @pending_source << @source_buffer[index] }
      
          @source_offset = 0
          @eof = raw_size == 0
          @source_size = translate_navigation_sequences(@eof)
          break if @source_size > 0 || @eof
        end
      end
      
      # Consume Alt scrolling locally in the input frontend, while translating the
      # existing Alt+K/J aliases into the Ctrl arrows understood by Reply 0.4.
      private def translate_navigation_sequences(eof : Bool) : Int32
        input_offset = 0
        output_size = 0
        limit = @pending_source.size
      
        while input_offset < limit
          if matches?(@pending_source, input_offset, limit, "\f")
            @keyboard.try &.enqueue('\u000c')
            input_offset += 1
          elsif matches?(@pending_source, input_offset, limit, "\u0017")
            @keyboard.try &.enqueue('\u0017')
            input_offset += 1
          elsif sequence = input_binding_sequence(input_offset, limit)
            binding, input_size = sequence
            @keyboard.try &.enqueue(binding)
            input_offset += input_size
          elsif sequence = alt_navigation_sequence(input_offset, limit)
            binding, input_size = sequence
            @navigation_bindings << binding
      
            translated = binding.action == Action::SelectPrevious ? "\e[1;5A" : "\e[1;5B"
            output_size += append_sequence(translated, output_size)
            input_offset += input_size
          elsif binding = control_navigation_binding(input_offset, limit)
            @navigation_bindings << binding
            translated = binding.action == Action::SelectPrevious ? "\e[1;5A" : "\e[1;5B"
            output_size += append_sequence(translated, output_size)
            input_offset += translated.bytesize
          elsif !eof && incomplete_sequence_prefix?(input_offset, limit)
            break
          else
            @read_buffer[output_size] = @pending_source[input_offset]
            output_size += 1
            input_offset += 1
          end
        end
      
        @pending_source.shift(input_offset) if input_offset > 0
        output_size
      end
      
      private def input_binding_sequence(offset : Int32, limit : Int32) : Tuple(SequenceBinding, Int32)?
        TmuxREPL::Keyboard::INPUT_ACTION_SEQUENCES.each do |sequence, label|
          if matches?(@pending_source, offset, limit, sequence)
            return {
              TmuxREPL::Keyboard.sequence_binding_for(label).not_nil!,
              sequence.bytesize,
            }
          end
        end
      end
      
      private def alt_navigation_sequence(offset : Int32, limit : Int32) : Tuple(SequenceBinding, Int32)?
        if matches?(@pending_source, offset, limit, "\ek")
          {TmuxREPL::Keyboard.sequence_binding_for("Alt+K").not_nil!, 2}
        elsif matches?(@pending_source, offset, limit, "\ej")
          {TmuxREPL::Keyboard.sequence_binding_for("Alt+J").not_nil!, 2}
        elsif matches?(@pending_source, offset, limit, "\e[107;3u")
          {TmuxREPL::Keyboard.sequence_binding_for("Alt+K").not_nil!, 8}
        elsif matches?(@pending_source, offset, limit, "\e[106;3u")
          {TmuxREPL::Keyboard.sequence_binding_for("Alt+J").not_nil!, 8}
        end
      end
      
      private def control_navigation_binding(offset : Int32, limit : Int32) : SequenceBinding?
        if matches?(@pending_source, offset, limit, "\e[1;5A")
          TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Up")
        elsif matches?(@pending_source, offset, limit, "\e[1;5B")
          TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Down")
        end
      end
      
      private def incomplete_sequence_prefix?(offset : Int32, limit : Int32) : Bool
        suffix = String.build do |io|
          index = offset
          while index < limit
            io.write_byte(@pending_source[index])
            index += 1
          end
        end
      
        TmuxREPL::Keyboard::INPUT_SEQUENCE_STRINGS.any? { |sequence| sequence.starts_with?(suffix) }
      end
      
      private def append_sequence(sequence : String, offset : Int32) : Int32
        bytes = sequence.to_slice
        @read_buffer[offset, bytes.size].copy_from(bytes)
        bytes.size
      end
      
      private def matches?(
        buffer : Array(UInt8),
        offset : Int32,
        limit : Int32,
        sequence : String
      ) : Bool
        bytes = sequence.to_slice
        return false if offset + bytes.size > limit
      
        bytes.size.times do |index|
          return false unless buffer[offset + index] == bytes[index]
        end
        true
      end
      
      private def matches?(
        buffer : Bytes,
        offset : Int32,
        limit : Int32,
        sequence : String
      ) : Bool
        bytes = sequence.to_slice
        return false if offset + bytes.size > limit
      
        bytes.size.times do |index|
          return false unless buffer[offset + index] == bytes[index]
        end
        true
      end
      
      # Keep Enter and each Ctrl navigation sequence in a separate read so Reply can
      # parse them even when ordinary text or another key arrived in the same OS read.
      private def bytes_before_line_ending(available : Int32) : Int32
        available.times do |index|
          offset = @source_offset + index
          byte = @read_buffer[offset]
      
          return index == 0 ? 1 : index if byte == '\r'.ord
          return index == 0 ? 1 : index if byte == '\n'.ord && index == available - 1
      
          if byte == '\e'.ord
            if sequence_size = navigation_sequence_size(offset, @source_size)
              return index == 0 ? sequence_size : index
            end
          end
        end
        available
      end
      
      private def navigation_sequence_size(offset : Int32, limit : Int32) : Int32?
        sequence = "\e[1;5A"
        return sequence.bytesize if matches?(@read_buffer, offset, limit, sequence)
      
        sequence = "\e[1;5B"
        return sequence.bytesize if matches?(@read_buffer, offset, limit, sequence)
      end
    end
  
    struct KeyPress
        getter character : Char
        getter key : String?
        getter action : Action?
        getter pressed_at : Time
        getter monotonic_at : Time::Instant
      
        def initialize(@character : Char, @action : Action?)
          @key = nil
          @monotonic_at = Time.instant
          @pressed_at = Time.utc
        end
      
        def initialize(@key : String, @action : Action)
          @character = '\0'
          @monotonic_at = Time.instant
          @pressed_at = Time.utc
        end
    end
  
    class Trace
      @file : File? = nil
      @previous_monotonic_at : Time::Instant?
      
      def initialize(session_name : String, pane : String, path : String? = nil)
        @pane = pane
        return unless path || trace_enabled?
      
        begin
          trace_path = path || self.class.path_for(session_name)
          FileUtils.mkdir_p(File.dirname(trace_path))
          @file = File.open(trace_path, "a")
          File.chmod(trace_path, 0o600)
        rescue ex
          @file.try &.close
          @file = nil
          STDERR.puts "tmux.repl.#{@pane}: cannot open keyboard trace: #{ex.message}"
        end
      end
      
      def self.path_for(session_name : String) : String
        session = ENV["TMUX_REPL_SESSION_NAME"]? || session_name
        TmuxREPL::State.open(session).log_path("keyboard.trace.log")
      end
      
      def record(press : KeyPress, action : String, result : String) : Nil
        return unless file = @file
      
        elapsed = if previous = @previous_monotonic_at
          (press.monotonic_at - previous).total_milliseconds.round(3).to_s
        else
          "first"
        end
      
        line = String.build do |io|
          io << "pressed_at=" << press.pressed_at.to_rfc3339(fraction_digits: 6)
          io << " pane=" << @pane
          io << " pid=" << Process.pid
          if key = press.key
          io << " key=" << key
        else
          io << " character=" << press.character.inspect
        end
          io << " action=" << action
          io << " elapsed_since_previous_ms=" << elapsed
          io << " result=" << result
          io << 10_u8.chr
        end
      
        file.flock_exclusive do
          file.write(line.to_slice)
          file.flush
        end
        @previous_monotonic_at = press.monotonic_at
      rescue ex
        STDERR.puts "tmux.repl.#{@pane}: cannot write keyboard trace: #{ex.message}"
      end
      
      def close : Nil
        if file = @file
          file.close unless file.closed?
        end
      rescue ex
        STDERR.puts "tmux.repl.#{@pane}: cannot close keyboard trace: #{ex.message}"
      ensure
        @file = nil
      end
      
      private def trace_enabled? : Bool
        ENV["LOG_LEVEL"]?.try(&.upcase) == "TRACE"
      end
    end
  
    class Dispatcher
      @queue : Queue(KeyPress)
      @state_mutex : Sync::Mutex
      @finished : Channel(Nil)
      @trace : Trace
      @on_action : Proc(Action, Nil)?
      @started = false
      @stopped = false
      @joined = false
      
      def initialize(
        @session_name : String,
        @pane : String,
        @events : AMQP::Client::Queue,
        @on_action : Proc(Action, Nil)? = nil
      )
        @queue = Queue(KeyPress).new
        @state_mutex = Sync::Mutex.new
        @finished = Channel(Nil).new(1)
        @trace = Trace.new(@session_name, @pane)
      end
      
      def start : Nil
        @state_mutex.synchronize do
          raise "Keyboard dispatcher has already been started or stopped" if @started || @stopped
          @started = true
        end
      
        spawn { consume }
        nil
      end
      
      # Queue every character before Reply edits it or Output reads the next one.
      def enqueue(character : Char) : Action?
        action = Keyboard.action_for(character)
        if @pane == "input" && (character == '\r' || character == '\n')
          action = Action::SubmitInput
        end
        press = KeyPress.new(character, action)
      
        @state_mutex.synchronize do
          @queue.push(press) unless @stopped
        end
      
        action
      end
      
      # Queue a parsed key sequence after its handler has decided what to do with it.
      def enqueue(binding : SequenceBinding) : Action
        press = KeyPress.new(binding.label, binding.action)
        @state_mutex.synchronize do
          @queue.push(press) unless @stopped
        end
        binding.action
      end
      
      # Close the queue and wait for the consumer to drain all pending characters.
      def stop : Nil
        should_wait = @state_mutex.synchronize do
          unless @stopped
            @stopped = true
            @queue.close
          end
      
          wait = @started && !@joined
          @joined = true if wait
          wait
        end
      
        @finished.receive if should_wait
      end
      
      private def consume : Nil
        loop do
          dispatch(@queue.pop)
        end
      rescue ex
        unless @queue.closed?
          STDERR.puts "tmux.repl.#{@pane}: keyboard dispatcher stopped: #{ex.message}"
          @state_mutex.synchronize do
            @stopped = true
            @queue.close unless @queue.closed?
          end
        end
      ensure
        @trace.close
        @finished.send(nil)
      end
      
      private def dispatch(press : KeyPress) : Nil
        action = press.action
        action_name = action ? action.to_s : (@pane == "input" ? "reply_input" : "none")
      
        result = case action
                 when Action::ToggleOutputView
                   begin
                     TmuxREPL.publish_event(@events, "toggle_view", @session_name, 0_u64)
                     "published"
                   rescue ex
                     STDERR.puts "tmux.repl.#{@pane}: failed to publish #{action}: #{ex.message}"
                     "publish_failed"
                   end
                 when Action::ToggleOutputList
                   begin
                     TmuxREPL.publish_event(@events, "toggle_list_view", @session_name, 0_u64)
                     "published"
                   rescue ex
                     STDERR.puts "tmux.repl.#{@pane}: failed to publish #{action}: #{ex.message}"
                     "publish_failed"
                   end
                 when Action::ToggleOutputWrap
                   begin
                     TmuxREPL.publish_event(@events, "toggle_wrap", @session_name, 0_u64)
                     "published"
                   rescue ex
                     STDERR.puts "tmux.repl.#{@pane}: failed to publish #{action}: #{ex.message}"
                     "publish_failed"
                   end
                 when Action::ToggleOutputZoom
                   begin
                     TmuxREPL.publish_event(
                       @events, "toggle_output_zoom", @session_name, 0_u64,
                       requesting_pane: ENV["TMUX_PANE"]?
                     )
                     "published"
                   rescue ex
                     STDERR.puts "tmux.repl.#{@pane}: failed to publish #{action}: #{ex.message}"
                     "publish_failed"
                   end
                 when Action::SelectPrevious, Action::SelectNext
                   "handled_by_input_reader"
                 when Action::ScrollUp, Action::ScrollDown, Action::ScrollPageUp, Action::ScrollPageDown,
                      Action::ScrollHorizontalLeft, Action::ScrollHorizontalRight,
                      Action::ScrollHorizontalStart, Action::ScrollHorizontalEnd
                   if @pane == "input"
                     begin
                       TmuxREPL.publish_event(
                         @events, "scroll", @session_name, 0_u64, action: action.not_nil!.to_s
                       )
                       "published"
                     rescue ex
                       STDERR.puts "tmux.repl.input: failed to publish #{action}: #{ex.message}"
                       "publish_failed"
                     end
                   else
                     @on_action.try &.call(action.not_nil!)
                     "handled_by_output_view"
                   end
                 when Action::SubmitInput
                   "handled_by_reply"
                 else
                   @pane == "input" ? "handled_by_reply" : "ignored"
                 end
      
        @trace.record(press, action_name, result)
      end
    end
  end

  class Session
    module Helpers
      private def amqp_environment : Hash(String, String)
        socket_path = ENV["LAVINMQ_AMQP_UNIXSOCKET"]?
        raise "Missing critical environment configuration variable: LAVINMQ_AMQP_UNIXSOCKET" unless socket_path
      
        environment = {"LAVINMQ_AMQP_UNIXSOCKET" => socket_path}
        environment.merge!(@environment)
        environment["TMUX_REPL_SESSION_NAME"] = @name
        environment["TMUX_REPL_SESSION_STATE"] = @state.base_path
      
        unless environment.has_key?("XDG_STATE_HOME")
          if state_home = ENV["XDG_STATE_HOME"]?
            environment["XDG_STATE_HOME"] = state_home
          end
        end
      
        unless environment.has_key?("LOG_LEVEL")
          if log_level = ENV["LOG_LEVEL"]?
            environment["LOG_LEVEL"] = log_level
          end
        end
      
        if TmuxREPL.trace_timing_enabled?
          environment["TMUX_REPL_TRACE_TIMING"] = "1"
          environment["TMUX_REPL_TRACE_FILE"] = @state.log_path("timing.log")
        end
        environment
      end
      
      private def state_dir : String
        @state.base_path
      end
      
      private def session_environment : Hash(String, String)
        environment = @environment.dup
        environment["TMUX_REPL_SESSION_NAME"] = @name
        environment["TMUX_REPL_SESSION_STATE"] = @state.base_path
        environment
      end
      
      private def resolved_input_executable : String
        override = @input_executable || ENV["TMUX_REPL_INPUT_EXECUTABLE"]?
        CompanionExecutable.resolve("tmux.repl.input", PROGRAM_NAME, override)
      end
      
      private def resolved_output_executable : String
        override = @output_executable || ENV["TMUX_REPL_OUTPUT_EXECUTABLE"]?
        CompanionExecutable.resolve("tmux.repl.output", PROGRAM_NAME, override)
      end
      
      private def resolved_worker_executable : String
        override = @worker_executable || ENV["TMUX_REPL_WORKER_EXECUTABLE"]?
        CompanionExecutable.resolve("tmux.repl.worker", PROGRAM_NAME, override)
      end
      
      private def shell_quote(value : String) : String
        "'#{value.gsub("'", "'\\''")}'"
      end
    end
  
    module Start
      module CreateSession
        private def create_session(server : Tmux::Server, focus : Bool) : Nil
          dir = state_dir
          session : Tmux::Session? = nil
          worker_process : Process? = nil
        
          begin
            @state.prepare
            if !@command && !@custom_command_mode
              File.write(File.join(dir, "input.startup"), "launching #{resolved_input_executable}")
            end
        
            created = if @command
              File.write(File.join(dir, "output.log"), "")
              server.new_session(
                name: @name,
                detached: true,
                start_directory: @start_directory,
                environment: session_environment
              )
            else
              server.new_session(
                name: @name,
                detached: true,
                start_directory: @start_directory,
                command: [resolved_input_executable, "--input", @name],
                environment: amqp_environment
              )
            end
            session = created
        
            if !@command && !@custom_command_mode
              wait_for_ready(File.join(dir, "input.pid"), resolved_input_executable)
              File.write(File.join(dir, "worker.startup"), "launching #{resolved_worker_executable}")
              worker_environment = {} of String => String?
              ENV.each { |key, value| worker_environment[key] = value }
              session_environment.each { |key, value| worker_environment[key] = value }
        
              worker_process = Process.new(
                resolved_worker_executable,
                ["--worker", @name, created.session_id],
                env: worker_environment,
                input: Process::Redirect::Close,
                output: Process::Redirect::Close,
                error: Process::Redirect::Close
              )
              wait_for_ready(File.join(dir, "worker.pid"), resolved_worker_executable)
            elsif @custom_command_mode
              wait_for_ready(File.join(dir, "input.pid"), resolved_input_executable)
            end
        
            configure_session(created)
        
            unless @command
              wait_for_ready(File.join(dir, "output.pid"), resolved_output_executable)
            end
        
            activate(created) if focus
          rescue ex
            if process = worker_process
              begin
                Process.signal(Signal::TERM, process.pid)
                process.wait
              rescue
              end
            end
            cleanup_failed_start(server, session, dir)
            STDERR.puts "tmux.repl: #{ex.message}"
            raise ex
          end
        end
        
        private def wait_for_ready(path : String, process_name : String) : Nil
          error_path = path.sub(/\.pid$/, ".error")
          stage_path = path.sub(/\.pid$/, ".startup")
          deadline = Time.instant + 5.seconds
        
          while Time.instant < deadline
            if File.exists?(error_path)
              details = File.read(error_path).strip
              raise "#{process_name} failed before readiness: #{details}"
            end
        
            return if File.exists?(path)
            sleep 10.milliseconds
          end
        
          if File.exists?(error_path)
            details = File.read(error_path).strip
            raise "#{process_name} failed before readiness: #{details}"
          end
        
          stage = File.read(stage_path).strip if File.exists?(stage_path)
          detail = stage ? " while #{stage}" : ""
          raise "Timed out waiting for #{process_name} readiness at #{path}#{detail}"
        end
        
        private def configure_session(session : Tmux::Session) : Nil
          window = session.active_window
          input_pane = window.active_pane
        
          if @command
            log = File.join(state_dir, "output.log")
            input_pane.run!("pipe-pane", "-o", "-t", input_pane.pane_id, "cat >> #{shell_quote(log)}")
            input_pane.split(
              :right,
              detached: true,
              command: [resolved_output_executable, "--log", log]
            )
            input_pane.send_keys(input_command, literal: true)
          else
            File.write(File.join(state_dir, "output.startup"), "launching #{resolved_output_executable}") unless @custom_command_mode
            input_pane.split(
              :right,
              detached: true,
              command: [resolved_output_executable, @name]
            )
            input_pane.select
          end
        
          window.select_layout("even-horizontal")
          input_pane.select
        end
        
        private def input_command : String
          @command.not_nil!.map { |argument| shell_quote(argument) }.join(" ")
        end
        
        private def cleanup_failed_start(server : Tmux::Server, session : Tmux::Session?, dir : String) : Nil
          begin
            if active_session = session
              active_session.kill
            else
              server.cmd("kill-session", "-t", @name)
            end
          rescue Tmux::Error
          end
          @state.cleanup_runtime
        end
      end
    
      def start(focus : Bool = true) : Nil
        # Resolve XDG_STATE_HOME when starting or attaching. Session objects may be
        # constructed before callers set their session-specific environment.
        @state = State.new(@name)
        server = current_server
        if session = find_session(server)
          activate(session) if focus
        else
          create_session(server, focus)
        end
      end
      
      include CreateSession
      
      private def current_server : Tmux::Server
        return Tmux::Server.new if ENV["TMUX"]?.nil?
        Tmux::Server.from_env
      end
      
      private def find_session(server : Tmux::Server) : Tmux::Session?
        return nil unless server.cmd("has-session", "-t", @name).success?
        server.session(@name)
      end
      
      private def activate(session : Tmux::Session) : Nil
        if ENV["TMUX"]?.nil?
          session.attach
        else
          session.switch_client
        end
      end
    end
  
    module Stop
      def stop : Nil
        stop_worker
      
        begin
          server = ENV["TMUX"]?.nil? ? Tmux::Server.new : Tmux::Server.from_env
          server.cmd("kill-session", "-t", @name)
        rescue Tmux::Error
        ensure
          @state.cleanup_runtime
        end
      end
      
      private def stop_worker : Nil
        ready_path = @state.path("worker.pid")
        unless File.exists?(ready_path) || File.exists?(@state.manifest_path)
          legacy_path = State.legacy_path(@name)
          ready_path = File.join(legacy_path, "worker.pid")
        end
        return unless File.exists?(ready_path)
      
        pid = File.read(ready_path).strip.to_i64?
        return unless pid
      
        begin
          Process.signal(Signal::TERM, pid)
        rescue
          return
        end
      
        deadline = Time.instant + 2.seconds
        while File.exists?(ready_path) && Time.instant < deadline
          sleep 10.milliseconds
        end
      
        if File.exists?(ready_path)
          begin
            Process.signal(Signal::KILL, pid)
          rescue
          end
        end
      end
    end
  
    getter name : String
    getter command : Array(String)?
    getter environment : Hash(String, String)
    getter start_directory : String?
    getter input_executable : String?
    getter output_executable : String?
    getter worker_executable : String?
    getter custom_command_mode : Bool
    getter state : State
    
    # Resolve companion executables in this order:
    # explicit override, sibling of tmux.repl, then caller's PATH.
    module CompanionExecutable
      def self.resolve(
        name : String,
        program_path : String,
        override : String? = nil,
        search_path : String? = ENV["PATH"]?
      ) : String
        if configured = override
          candidate = if configured.includes?('/')
            File.expand_path(configured)
          else
            find_on_path(configured, search_path)
          end
    
          return candidate if candidate && File::Info.executable?(candidate)
    
          raise "Configured executable override #{configured.inspect} for #{name.inspect} is not executable or could not be found on PATH"
        end
    
        program_path = File.expand_path(program_path)
        sibling = File.join(File.dirname(program_path), name)
        return sibling if File::Info.executable?(sibling)
    
        if candidate = find_on_path(name, search_path)
          return candidate
        end
    
        raise "Cannot find executable #{name.inspect} beside #{program_path.inspect} or on PATH"
      end
    
      private def self.find_on_path(name : String, search_path : String?) : String?
        return nil unless search_path
    
        search_path.split(':').each do |directory|
          directory = "." if directory.empty?
          candidate = File.expand_path(name, directory)
          return candidate if File::Info.executable?(candidate)
        end
    
        nil
      end
    end
    
    def initialize(
      @name : String,
      @command : Array(String)? = nil,
      @environment : Hash(String, String) = {} of String => String,
      @start_directory : String? = nil,
      @input_executable : String? = nil,
      @output_executable : String? = nil,
      @worker_executable : String? = nil,
      @custom_command_mode : Bool = false
    )
      @state = State.new(@name)
    
      if command = @command
        raise ArgumentError.new("REPL command must not be empty") if command.empty?
        raise ArgumentError.new("A custom REPL cannot also configure a native command") if @custom_command_mode
      end
    end
    
    include Start
    include Stop
    include Helpers
  end

  class State
      MANIFEST_NAME = "session.yml"
      LOG_DIRECTORY = "logs"
      RUNTIME_FILES = [
        "input.pid",
        "input.startup",
        "output.pid",
        "output.startup",
        "worker.pid",
        "worker.startup",
        "output.log",
      ]
    
      getter session_name : String
      getter base_path : String
    
      def initialize(@session_name : String)
        @base_path = self.class.session_path(@session_name)
      end
    
      def initialize(@session_name : String, @base_path : String)
      end
    
      # Create the session directory and its manifest before any companion process
      # starts. A manifest already present must describe this exact session.
      def prepare : Nil
        FileUtils.mkdir_p(self.class.application_root)
        File.chmod(self.class.application_root, 0o700)
    
        FileUtils.mkdir_p(self.class.sessions_path)
        File.chmod(self.class.sessions_path, 0o700)
    
        FileUtils.mkdir_p(@base_path)
        File.chmod(@base_path, 0o700)
    
        FileUtils.mkdir_p(logs_path)
        File.chmod(logs_path, 0o700)
    
        if File.exists?(manifest_path)
          existing = self.class.read(@base_path)
          unless existing.session_name == @session_name
            raise "Session state directory #{@base_path.inspect} belongs to #{existing.session_name.inspect}"
          end
        else
          File.write(manifest_path, manifest_contents)
          File.chmod(manifest_path, 0o600)
        end
      end
    
      def manifest_path : String
        path(MANIFEST_NAME)
      end
    
      def path(name : String) : String
        File.join(@base_path, name)
      end
    
      # Diagnostic files live separately from short-lived process markers.
      def log_path(name : String) : String
        if name.empty? || File.basename(name) != name || name == "." || name == ".."
          raise ArgumentError.new("Log name must be a simple file name: #{name.inspect}")
        end
    
        FileUtils.mkdir_p(logs_path)
        File.join(logs_path, name)
      end
    
      # Stop removes transient runtime files but retains the manifest, error
      # diagnostics, and logs so a session can still be inspected afterwards.
      def cleanup_runtime : Nil
        RUNTIME_FILES.each do |name|
          file = path(name)
          File.delete(file) if File.exists?(file)
        end
      end
    
      def self.application_root : String
        state_home = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
        File.join(File.expand_path(state_home), "tmux.repl")
      end
    
      def self.sessions_path : String
        File.join(application_root, "sessions")
      end
    
      def self.smoke_tests_path : String
        File.join(application_root, "smoke-tests")
      end
    
      def self.session_path(session_name : String) : String
        File.join(sessions_path, directory_name(session_name))
      end
    
      # Read an existing session manifest without needing its original Tmux name.
      def self.read(base_path : String) : self
        expanded_path = File.expand_path(base_path)
        yaml_path = File.join(expanded_path, MANIFEST_NAME)
        raise "Session manifest not found at #{yaml_path}" unless File.exists?(yaml_path)
    
        manifest = YAML.parse(File.read(yaml_path))
        session_name = manifest["session_name"].as_s
        recorded_base_path = File.expand_path(manifest["base_path"].as_s)
    
        unless recorded_base_path == expanded_path
          raise "Session manifest at #{yaml_path} records base_path #{recorded_base_path.inspect}, not #{expanded_path.inspect}"
        end
    
        new(session_name, recorded_base_path)
      end
    
      # Companion processes prefer the explicit path supplied by the manager.
      # The deterministic lookup is a fallback for manually launched processes.
      def self.open(session_name : String) : self
        base_path = ENV["TMUX_REPL_SESSION_STATE"]? || session_path(session_name)
        state = read(base_path)
    
        unless state.session_name == session_name
          raise "Session state at #{base_path.inspect} belongs to #{state.session_name.inspect}, not #{session_name.inspect}"
        end
    
        state
      end
    
      # Location used by releases predating the session manifest. Kept only so
      # stop can terminate a worker left behind by an older tmux.repl process.
      def self.legacy_path(session_name : String) : String
        state_home = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
        File.join(File.expand_path(state_home), "tmux-repl", session_name)
      end
    
      private def self.directory_name(session_name : String) : String
        slug = session_name.gsub(/[^a-zA-Z0-9_-]+/, "-")
        slug = slug.gsub(/-+/, "-").gsub(/\A[-_.]+|[-_.]+\z/, "")
        slug = "session" if slug.empty?
        slug = slug[0, 48]
    
        "#{slug}-#{Digest::SHA256.hexdigest(session_name)[0, 12]}"
      end
    
      private def logs_path : String
        File.join(@base_path, LOG_DIRECTORY)
      end
    
      private def manifest_contents : String
        YAML.build do |yaml|
          yaml.mapping do
            yaml.scalar "session_name"
            yaml.scalar @session_name
            yaml.scalar "base_path"
            yaml.scalar @base_path
          end
        end
      end
  end

  class TerminalMode
    @saved_state : String?
    
    def enable : Bool
      return false unless STDIN.tty?
    
      state = IO::Memory.new
      status = Process.run(
        "stty",
        ["-g"],
        input: STDIN,
        output: state,
        error: Process::Redirect::Close
      )
      return false unless status.success?
    
      saved_state = state.to_s.strip
      return false if saved_state.empty?
      @saved_state = saved_state
    
      status = Process.run(
        "stty",
        ["-echo", "-icanon", "min", "1", "time", "0"],
        input: STDIN,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )
      unless status.success?
        restore
        return false
      end
    
      true
    rescue
      restore
      false
    end
    
    def restore : Nil
      state = @saved_state
      @saved_state = nil
      return unless state
    
      Process.run(
        "stty",
        [state],
        input: STDIN,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )
      nil
    rescue
      nil
    end
  end

  class Testing
    DEFAULT_TIMEOUT = 8.seconds
    START_TIMEOUT = 8.seconds
    HOST_STOP_TIMEOUT = 5.seconds
    
    @server : Tmux::Server
    @origin_session : Tmux::Session
    @origin_session_name : String
    @session_name : String?
    @input_pane : Tmux::Pane?
    @output_pane : Tmux::Pane?
    @cleanup : Symbol
    @restore_client : Bool
    @step_delay : Time::Span
    @started_at : Time
    @stage = "initialize"
    @sequence = 0
    @definition : Definition?
    @definition_host_result : Channel(String)?
    @host_process : Process?
    @host_exit : Channel(Process::Status)?
    @host_status : Process::Status?
    @host_log : File?
    @host_log_path : String?
    @event_channel : Channel(Event)?
    @failure : Exception?
    @session_cleaned = false
    @report = [] of NamedTuple(
      name: String,
      passed: Bool,
      duration_ms: Float64,
      details: String
    )
    
    struct Configuration
      getter focus : Bool
      getter cleanup : Symbol
      getter restore_client : Bool
      getter step_delay : Time::Span
      getter timeout : Time::Span
      getter start_timeout : Time::Span
      getter host_stop_timeout : Time::Span
    
      def initialize(
        @focus : Bool,
        @cleanup : Symbol,
        @restore_client : Bool,
        @step_delay : Time::Span,
        @timeout : Time::Span,
        @start_timeout : Time::Span,
        @host_stop_timeout : Time::Span
      )
        unless @cleanup == :always || @cleanup == :never || @cleanup == :on_failure
          raise ArgumentError.new("cleanup must be always, never, or on_failure; got #{@cleanup.inspect}")
        end
    
        if @focus && @cleanup != :never && !@restore_client
          raise ArgumentError.new("restore_client must be enabled when a focused test session may be cleaned up")
        end
      end
    
      def self.from_env(
        name : String,
        focus : Bool,
        cleanup : Symbol,
        restore_client : Bool,
        step_delay : Time::Span,
        timeout : Time::Span,
        start_timeout : Time::Span,
        host_stop_timeout : Time::Span
      ) : self
        new(
          boolean(name, "FOCUS", focus),
          cleanup_policy(name, cleanup),
          boolean(name, "RESTORE_CLIENT", restore_client),
          duration(name, "DELAY", step_delay),
          duration(name, "TIMEOUT", timeout),
          duration(name, "START_TIMEOUT", start_timeout),
          duration(name, "HOST_STOP_TIMEOUT", host_stop_timeout)
        )
      end
    
      private def self.environment_value(name : String, setting : String) : String?
        scenario = (name.split('.').last? || name).gsub(/[^a-zA-Z0-9]/, "_").upcase
        full_name = name.gsub(/[^a-zA-Z0-9]/, "_").upcase
    
        ENV["TMUX_REPL_TEST_#{scenario}_#{setting}"]? ||
          ENV["TMUX_REPL_TEST_#{full_name}_#{setting}"]? ||
          ENV["TMUX_REPL_TEST_#{setting}"]?
      end
    
      private def self.boolean(name : String, setting : String, default : Bool) : Bool
        value = environment_value(name, setting)
        return default unless value
    
        case value.downcase
        when "1", "true", "yes", "on"
          true
        when "0", "false", "no", "off"
          false
        else
          raise ArgumentError.new("Invalid boolean for TMUX_REPL_TEST_#{setting}: #{value.inspect}")
        end
      end
    
      private def self.cleanup_policy(name : String, default : Symbol) : Symbol
        value = environment_value(name, "CLEANUP")
        return default unless value
    
        case value.downcase
        when "always"
          :always
        when "never"
          :never
        when "on_failure"
          :on_failure
        else
          raise ArgumentError.new("Invalid cleanup policy for TMUX_REPL_TEST_CLEANUP: #{value.inspect}")
        end
      end
    
      private def self.duration(name : String, setting : String, default : Time::Span) : Time::Span
        value = environment_value(name, setting)
        return default unless value
    
        seconds = value.to_f?
        unless seconds && seconds >= 0
          raise ArgumentError.new("Expected non-negative seconds for TMUX_REPL_TEST_#{setting}, got #{value.inspect}")
        end
    
        seconds.seconds
      end
    end
    
    struct Event
      getter type : String
      getter sequence : Int64
      getter chunk : String?
      getter status : Int32?
      getter clean_output : String?
    
      def initialize(
        @type : String,
        @sequence : Int64,
        @chunk : String?,
        @status : Int32?,
        @clean_output : String?
      )
      end
    end
    
    class CommandResult
      getter sequence : Int32
      getter command : String
      getter status : Int32?
    
      @output = ""
      @completed = false
    
      def initialize(
        @runner : Testing,
        @sequence : Int32,
        @command : String
      )
        @status = nil
      end
    
      # Wait for protocol output first, then verify that the Output pane rendered it.
      def expect_output(
        *expected : String,
        timeout : Time::Span? = nil
      ) : self
        expected_items = expected.to_a
        timeout = timeout || @runner.timeout
        deadline = Time.instant + timeout
    
        until expected_items.all? { |item| output.includes?(item) } || @completed
          remaining = deadline - Time.instant
          raise "Timed out waiting for command ##{@sequence} output; received: #{output.inspect}" if remaining <= Time::Span.zero
          @runner.receive_command_event(self, remaining)
        end
    
        missing = expected_items.reject { |item| output.includes?(item) }
        raise "Command ##{@sequence} completed without expected output #{missing.map(&.inspect).join(", ")}; received: #{output.inspect}" unless missing.empty?
    
        @runner.expect_command_output(@sequence, expected_items, timeout)
        self
      end
    
      def expect_status(
        status : Int32,
        timeout : Time::Span? = nil
      ) : self
        timeout = timeout || @runner.timeout
        wait_for_completion(timeout)
        raise "Command ##{@sequence} exited with status #{@status.inspect}, expected #{status}." unless @status == status
    
        @runner.expect_command_status(@sequence, status, timeout)
        self
      end
    
      def expect_complete(
        timeout : Time::Span? = nil
      ) : self
        timeout = timeout || @runner.timeout
        wait_for_completion(timeout)
        @runner.expect_command_complete(@sequence, timeout)
        self
      end
    
      def output : String
        @output
      end
    
      def accept(event : Event) : Nil
        if event.type == "output"
          @output += event.chunk.not_nil! if event.chunk
        elsif event.type == "complete"
          @status = event.status
          @completed = true
          if @output.empty? && (clean = event.clean_output)
            @output = clean
          end
        end
      end
    
      private def wait_for_completion(timeout : Time::Span) : Nil
        deadline = Time.instant + timeout
        until @completed
          remaining = deadline - Time.instant
          raise "Timed out waiting for command ##{@sequence} completion." if remaining <= Time::Span.zero
          @runner.receive_command_event(self, remaining)
        end
      end
    end
    
    def self.run(
      name : String,
      cleanup : Symbol = :never,
      focus : Bool = true,
      restore_client : Bool = true,
      step_delay : Time::Span = 0.seconds,
      timeout : Time::Span = DEFAULT_TIMEOUT,
      start_timeout : Time::Span = START_TIMEOUT,
      host_stop_timeout : Time::Span = HOST_STOP_TIMEOUT,
      &scenario : Testing ->
    ) : Nil
      configuration = Configuration.from_env(
        name,
        focus,
        cleanup,
        restore_client,
        step_delay,
        timeout,
        start_timeout,
        host_stop_timeout
      )
      runner = new(name, configuration)
      runner.run { yield runner }
    end

    def self.run(
      scenario_class : T.class,
      name : String,
      cleanup : Symbol = :never,
      focus : Bool = true,
      restore_client : Bool = true,
      step_delay : Time::Span = 0.seconds,
      timeout : Time::Span = DEFAULT_TIMEOUT,
      start_timeout : Time::Span = START_TIMEOUT,
      host_stop_timeout : Time::Span = HOST_STOP_TIMEOUT
    ) : Nil forall T
      configuration = Configuration.from_env(
        name,
        focus,
        cleanup,
        restore_client,
        step_delay,
        timeout,
        start_timeout,
        host_stop_timeout
      )
      scenario = scenario_class.new(name, configuration)
      scenario.run { scenario.execute_steps }
    end
    
    def initialize(
      @name : String,
      configuration : Configuration
    )
      unless ENV["TMUX"]? && ENV["TMUX_PANE"]?
        raise "Run this smoke test from inside the Tmux session to return to."
      end
    
      @configuration = configuration
      @cleanup = configuration.cleanup
      @focus = configuration.focus
      @restore_client = configuration.restore_client
      @step_delay = configuration.step_delay
      @timeout = configuration.timeout
      @start_timeout = configuration.start_timeout
      @host_stop_timeout = configuration.host_stop_timeout
    
      @server = Tmux::Server.from_env
      @origin_session = Tmux::Session.from_env
      @origin_session_name = @origin_session.session_name
      @started_at = Time.utc
    end
    
    getter timeout : Time::Span
    
    def run(&scenario : Testing ->) : Nil
      begin
        yield self
      rescue ex
        @failure = ex
        last = @report.last?
        unless last && !last[:passed]
          @report << {
            name: "Smoke test",
            passed: false,
            duration_ms: 0.0,
            details: "#{@stage}: #{ex.class}: #{ex.message}",
          }
        end
      ensure
        finish
      end
    
      report_path = write_machine_report
      print_report(report_path)
      raise @failure.not_nil! if @failure
    end
    
    def session_name : String
      @session_name || raise "The REPL session has not been started."
    end
    
    def session_exists?(name : String) : Bool
      @server.cmd("has-session", "-t", name).success?
    end
    
    # Start the regular CLI and identify the single new session it creates.
    def start_cli(
      executable : String,
      arguments : Array(String) = ["start"]
    ) : self
      raise "A REPL session has already been started." if @session_name
      raise "Missing #{executable}. Build the executables first with shards build." unless File::Info.executable?(executable)
    
      existing_session_ids = @server.sessions.map(&.session_id)
      environment = {} of String => String?
      ENV.each { |key, value| environment[key] = value }
      environment["TMUX_REPL_SESSION"] = nil
      cli_arguments = arguments.dup
      cli_arguments << "--no-focus" unless @focus || cli_arguments.includes?("--no-focus")
    
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(
        executable,
        cli_arguments,
        env: environment,
        output: stdout,
        error: stderr
      )
      unless status.success?
        raise "#{executable} #{arguments.join(" ")} failed (#{status.exit_code}).\n#{stdout}\n#{stderr}"
      end
    
      created : Tmux::Session? = nil
      found = wait_until(@start_timeout) do
        candidates = @server.sessions.select do |session|
          !existing_session_ids.includes?(session.session_id) &&
            session.session_name.starts_with?("#{@origin_session_name}|repl-")
        end
    
        raise "Expected one new REPL session, found #{candidates.size}." if candidates.size > 1
    
        created = candidates.first?
        !created.nil?
      end
    
      unless found
        raise "Could not find the session created by #{executable} #{arguments.join(" ")}."
      end
    
      @session_name = created.not_nil!.session_name
      attach_session
      ensure_foreground! if @focus
      self
    end
    
    
    # Start a custom REPL application in a separate process. The expected session
    # name is explicit, so discovery never depends on a session-name prefix.
    def start_host(
      executable : String,
      arguments : Array(String),
      expected_session_name : String
    ) : self
      raise "A REPL session has already been started." if @session_name
      raise "Missing #{executable}. Build the executables first with shards build." unless File::Info.executable?(executable)
      raise "Custom REPL tests require cleanup: :always." unless @cleanup == :always
      if @server.cmd("has-session", "-t", expected_session_name).success?
        raise "Tmux session #{expected_session_name.inspect} already exists."
      end
    
      @session_name = expected_session_name
      FileUtils.mkdir_p(State.smoke_tests_path)
      @host_log_path = File.join(
        State.smoke_tests_path,
        "custom-host-#{Process.pid}-#{Time.utc.to_unix_ms}.log"
      )
      @host_log = File.open(@host_log_path.not_nil!, "w")
    
      host_arguments = arguments.dup
      host_arguments << "--no-focus" unless @focus || host_arguments.includes?("--no-focus")
    
      process = Process.new(
        executable,
        host_arguments,
        env: {"TMUX_REPL_SESSION" => nil},
        input: Process::Redirect::Close,
        output: @host_log.not_nil!,
        error: @host_log.not_nil!
      )
      @host_process = process
    
      exit_channel = Channel(Process::Status).new(1)
      @host_exit = exit_channel
      spawn do
        exit_channel.send(process.wait)
      end
    
      ready = wait_until(@start_timeout) do
        raise_host_exit!
        custom_session_ready?(expected_session_name)
      end
      unless ready
        raise "Timed out waiting for custom REPL #{expected_session_name.inspect} to become ready. #{host_diagnostics}"
      end
    
      attach_session
      ensure_foreground! if @focus
      self
    end
    
    # Start a custom REPL in this process so its handlers retain access to
    # application-owned objects. Custom test sessions are always temporary.
    def start_custom(definition : Definition) : self
      raise "A REPL session has already been started." if @session_name
      raise ArgumentError.new("start_custom requires at least one custom command.") unless definition.custom_commands?
      if @server.cmd("has-session", "-t", definition.name).success?
        raise "Tmux session #{definition.name.inspect} already exists."
      end
    
      raise "Custom REPL tests require cleanup: :always." unless @cleanup == :always
    
      definition.start(focus: @focus)
      @definition = definition
      @session_name = definition.name
    
      host_result = Channel(String).new(1)
      @definition_host_result = host_result
      spawn do
        result = ""
        begin
          definition.serve
        rescue ex
          result = "#{ex.class}: #{ex.message}"
        ensure
          host_result.send(result)
        end
      end
    
      attach_session
      ensure_foreground! if @focus
      self
    end
    
    def step(name : String, &block : -> T) : Nil forall T
      record_step(name) { yield }
    end

    private def record_step(name : String, &block : -> T) : Nil forall T
      started_at = Time.instant
      @stage = name

      begin
        yield
        @report << {
          name: name,
          passed: true,
          duration_ms: (Time.instant - started_at).total_milliseconds,
          details: "",
        }
        sleep @step_delay if @step_delay.total_nanoseconds > 0
      rescue ex
        @report << {
          name: name,
          passed: false,
          duration_ms: (Time.instant - started_at).total_milliseconds,
          details: "#{ex.class}: #{ex.message}",
        }
        raise ex
      end
    end
    
    def submit(command : String) : CommandResult
      @sequence += 1
      input_pane.send_keys(command, literal: true)
      CommandResult.new(self, @sequence, command)
    end
    
    def press(pane : Symbol, key : String) : Nil
      target = case pane
               when :input
                 input_pane
               when :output
                 output_pane
               else
                 raise ArgumentError.new("pane must be :input or :output, got #{pane.inspect}")
               end
      target.send_keys(key, enter: false)
    end
    
    def expect_visible(
      *expected : String,
      timeout : Time::Span? = nil
    ) : Nil
      expect_visible_items(expected.to_a, timeout || @timeout)
    end
    
    def expect_visible_items(
      expected_items : Array(String),
      timeout : Time::Span = DEFAULT_TIMEOUT
    ) : Nil
      last_text = ""
      found = wait_until(timeout) do
        last_text = current_output
        expected_items.all? { |item| last_text.includes?(item) }
      end
      return if found
    
      missing = expected_items.reject { |item| last_text.includes?(item) }
      raise "Timed out waiting for the Output pane to show #{missing.map(&.inspect).join(", ")}.\n#{last_text}"
    end
    
    def expect_output_without(marker : String) : Nil
      text = current_output
      raise "Output pane still contains #{marker.inspect}.\n#{text}" if text.includes?(marker)
    end
    
    def expect_selected_input(sequence : Int32) : Nil
      expect_visible("INPUT ##{sequence}")
    end
    
    def expect_zoomed(expected : Bool) : Nil
      found = wait_until do
        zoomed = output_pane.display_message("\#{window_zoomed_flag}") == "1"
        zoomed == expected && (!expected || output_pane.active?)
      end
      return if found
    
      actual = output_pane.display_message("\#{window_zoomed_flag}") == "1"
      raise "Expected Output pane zoomed=#{expected}, got #{actual}."
    end
    
    def select_pane(pane : Symbol) : Nil
      target = case pane
               when :input
                 input_pane
               when :output
                 output_pane
               else
                 raise ArgumentError.new("pane must be :input or :output, got #{pane.inspect}")
               end
      target.select
    end
    
    def expect_active_pane(pane : Symbol) : Nil
      target = case pane
               when :input
                 input_pane
               when :output
                 output_pane
               else
                 raise ArgumentError.new("pane must be :input or :output, got #{pane.inspect}")
               end
    
      return if wait_until { target.active? }
    
      actual = if input_pane.active?
        :input
      elsif output_pane.active?
        :output
      else
        :none
      end
      raise "Expected #{pane} pane to be active, got #{actual}."
    end
    
    def receive_command_event(result : CommandResult, timeout : Time::Span) : Nil
      events = @event_channel || raise "The REPL event consumer has not started."
    
      if host_exit = @host_exit
        select
        when event = events.receive
          result.accept(event) if event.sequence == result.sequence.to_i64
        when status = host_exit.receive
          @host_status = status
          raise_host_exit!(status)
        when timeout(timeout)
          raise "Timed out waiting for a protocol event for command ##{result.sequence}."
        end
      else
        select
        when event = events.receive
          result.accept(event) if event.sequence == result.sequence.to_i64
        when timeout(timeout)
          raise "Timed out waiting for a protocol event for command ##{result.sequence}."
        end
      end
    end
    
    def expect_command_output(
      sequence : Int32,
      expected : Array(String),
      timeout : Time::Span
    ) : Nil
      expect_visible_items(["INPUT ##{sequence}"] + expected, timeout)
    end
    
    def expect_command_status(
      sequence : Int32,
      status : Int32,
      timeout : Time::Span
    ) : Nil
      expect_visible("INPUT ##{sequence}", "[exit status: #{status}]", timeout: timeout)
    end
    
    def expect_command_complete(
      sequence : Int32,
      timeout : Time::Span
    ) : Nil
      last_text = ""
      found = wait_until(timeout) do
        last_text = current_output
        last_text.includes?("INPUT ##{sequence}") && last_text.includes?("[exit status:")
      end
      return if found
    
      raise "Timed out waiting for command ##{sequence} to complete.\n#{last_text}"
    end
    
    def current_output : String
      pane_text(output_pane)
    end
    
    private def start_event_consumer : Nil
      name = @session_name || raise "The REPL session has not been identified."
      queue = TmuxREPL.stream_queue(
        Global.amqp_channel,
        TmuxREPL.events_queue_name(name)
      )
      events = Channel(Event).new(256)
      @event_channel = events
    
      queue.subscribe(
        no_ack: false,
        block: false,
        args: AMQ::Protocol::Table.new(
          {"x-stream-offset" => "next"} of String => AMQ::Protocol::Field
        )
      ) do |message|
        begin
          data = JSON.parse(message.body_io.to_s)
          if data["session"]?.try(&.as_s) == name
            sequence = data["sequence"]?.try(&.as_i64) || 0_i64
            status = data["status"]?.try { |value| value.as_i64.to_i32 }
            chunk = data["chunk"]?.try(&.as_s)
            clean_output = data["clean_output"]?.try(&.as_s)
            events.send(Event.new(data["type"].as_s, sequence, chunk, status, clean_output))
          end
          message.ack
        rescue ex
          STDERR.puts "tmux.repl.testing: could not read event: #{ex.class}: #{ex.message}"
          begin
            message.reject(requeue: false)
          rescue
          end
        end
      end
    end
    
    private def attach_session : Nil
      name = @session_name || raise "The REPL session has not been identified."
      session = @server.session(name)
      panes = session.active_window.panes
      raise "Expected two panes in #{name.inspect}, found #{panes.size}." unless panes.size == 2
    
      @input_pane = panes[0]
      @output_pane = panes[1]
      start_event_consumer
    end
    
    private def ensure_foreground! : Nil
      current = current_client_session_name
      expected = @session_name
      raise "Expected the foreground Tmux session to be #{expected.inspect}, got #{current.inspect}." unless current == expected
    end
    
    private def input_pane : Tmux::Pane
      @input_pane || raise "Input pane is not available."
    end
    
    private def output_pane : Tmux::Pane
      @output_pane || raise "Output pane is not available."
    end
    
    private def pane_text(pane : Tmux::Pane) : String
      pane.capture_pane(join_wrapped: true).join("\n")
    end
    
    private def wait_until(
      timeout : Time::Span? = nil,
      interval : Time::Span = 25.milliseconds,
      &condition : -> Bool
    ) : Bool
      deadline = Time.instant + (timeout || @timeout)
      while Time.instant < deadline
        return true if yield
        sleep interval
      end
      yield
    end
    
    private def current_client_session_name : String?
      output = IO::Memory.new
      status = Process.run(
        "tmux",
        ["display-message", "-p", "\#{client_session}"],
        output: output,
        error: Process::Redirect::Close
      )
      return nil unless status.success?
    
      output.to_s.strip
    rescue
      nil
    end
    
    private def finish : Nil
      if @output_pane
        cleanup_step("Restore Output pane zoom") { restore_output_zoom }
      end
    
      if @restore_client && @focus
        cleanup_step("Return to original session") { return_to_origin }
      end
    
      should_cleanup = @cleanup == :always || (@cleanup == :on_failure && !@failure.nil?)
      if should_cleanup && @session_name
        cleanup_step("Clean up REPL session") { cleanup_session }
      end
    end
    
    private def cleanup_step(name : String, &block : ->) : Nil
      started_at = Time.instant
      begin
        yield
        @report << {
          name: name,
          passed: true,
          duration_ms: (Time.instant - started_at).total_milliseconds,
          details: "",
        }
      rescue ex
        @report << {
          name: name,
          passed: false,
          duration_ms: (Time.instant - started_at).total_milliseconds,
          details: "#{ex.class}: #{ex.message}",
        }
        @failure ||= ex
      end
    end
    
    private def restore_output_zoom : Nil
      pane = @output_pane
      return unless pane
      return unless pane.display_message("\#{window_zoomed_flag}") == "1"
    
      pane.select
      pane.run!("resize-pane", "-Z", "-t", pane.pane_id)
    end
    
    private def return_to_origin : Nil
      @origin_session.switch_client
      restored = wait_until { current_client_session_name == @origin_session_name }
      raise "The Tmux client did not return to #{@origin_session_name.inspect}." unless restored
    end
    
    private def cleanup_session : Nil
      name = @session_name
      failure : Exception? = nil
    
      if definition = @definition
        begin
          definition.stop
        rescue ex
          failure = ex
          @server.cmd("kill-session", "-t", name.not_nil!) if name
        end
    
        begin
          wait_for_custom_host
        rescue ex
          failure ||= ex
        end
      else
        if name
          begin
            Session.new(name).stop
          rescue ex
            failure = ex
            @server.cmd("kill-session", "-t", name)
          end
        end
    
        begin
          stop_host_process
        rescue ex
          failure ||= ex
        end
      end
    
      if name
        removed = wait_until(@host_stop_timeout) do
          !@server.cmd("has-session", "-t", name).success?
        end
        failure ||= Exception.new("Tmux session #{name.inspect} was not removed.") unless removed
      end
    
      raise failure.not_nil! if failure
      @session_cleaned = true
    end
    
    private def wait_for_custom_host : Nil
      result = @definition_host_result || return
      message = ""
    
      select
      when value = result.receive
        message = value
      when timeout(@host_stop_timeout)
        raise "Timed out waiting for the in-process custom command host to stop."
      end
    
      raise "Custom command host failed: #{message}" unless message.empty?
    end
    
    private def custom_session_ready?(name : String) : Bool
      return false unless @server.cmd("has-session", "-t", name).success?
    
      state = State.new(name)
      return false unless File.exists?(state.path("input.pid"))
      return false unless File.exists?(state.path("output.pid"))
    
      @server.session(name).active_window.panes.size == 2
    end
    
    private def host_exit_status(timeout : Time::Span) : Process::Status?
      return @host_status if @host_status
    
      channel = @host_exit || return nil
      select
      when status = channel.receive
        @host_status = status
      when timeout(timeout)
      end
    
      @host_status
    end
    
    private def raise_host_exit! : Nil
      status = host_exit_status(0.seconds)
      raise_host_exit!(status) if status
    end
    
    private def raise_host_exit!(status : Process::Status) : NoReturn
      close_host_log
      raise "Custom REPL host process exited with status #{status.exit_code}. #{host_diagnostics}"
    end
    
    private def stop_host_process : Nil
      process = @host_process
      unless process
        close_host_log
        return
      end
    
      status = host_exit_status(@host_stop_timeout)
      unless status
        begin
          process.terminate
        rescue
        end
        status = host_exit_status(@host_stop_timeout)
      end
      unless status
        begin
          process.terminate(graceful: false)
        rescue
        end
        status = host_exit_status(@host_stop_timeout)
      end
    
      unless status
        raise "Timed out waiting for custom REPL host process #{process.pid} to exit after termination. #{host_diagnostics}"
      end
    
      close_host_log
      raise "Custom REPL host exited with status #{status.exit_code}. #{host_diagnostics}" unless status.success?
    end
    
    private def close_host_log : Nil
      @host_log.try &.close
      @host_log = nil
    end
    
    private def host_diagnostics : String
      path = @host_log_path
      return "Host log unavailable." unless path
    
      contents = File.exists?(path) ? File.read(path).strip : ""
      contents.empty? ? "Host log: #{path}" : "Host log: #{path}\n#{contents}"
    rescue ex
      "Could not read custom host log: #{ex.message}"
    end
    
    private def write_machine_report : String
      passed = @report.all? { |check| check[:passed] }
      finished_at = Time.utc.to_unix_ms
      directory = State.smoke_tests_path
      FileUtils.mkdir_p(directory)
    
      path = File.join(directory, "smoke-test-#{@started_at.to_unix_ms}-#{Process.pid}.json")
      temporary_path = "#{path}.tmp"
    
      contents = JSON.build(indent: "  ") do |json|
        json.object do
          json.field "schema_version", 1
          json.field "test", @name
          json.field "status", passed ? "passed" : "failed"
          json.field "exit_code", passed ? 0 : 1
          json.field "started_at_unix_ms", @started_at.to_unix_ms
          json.field "finished_at_unix_ms", finished_at
          json.field "original_session", @origin_session_name
          json.field "smoke_test_session", @session_name
          json.field "custom_host_pid", @host_process.try(&.pid)
          json.field "custom_host_log", @host_log_path
          json.field "session_cleaned", @session_cleaned
          json.field "configuration" do
            json.object do
              json.field "focus", @focus
              json.field "cleanup", @cleanup.to_s
              json.field "restore_client", @restore_client
              json.field "step_delay_seconds", @step_delay.total_seconds
              json.field "timeout_seconds", @timeout.total_seconds
              json.field "start_timeout_seconds", @start_timeout.total_seconds
              json.field "host_stop_timeout_seconds", @host_stop_timeout.total_seconds
            end
          end
          json.field "checks" do
            json.array do
              @report.each do |check|
                json.object do
                  json.field "name", check[:name]
                  json.field "status", check[:passed] ? "passed" : "failed"
                  json.field "duration_ms", check[:duration_ms]
                  json.field "details", check[:details]
                end
              end
            end
          end
        end
      end
    
      File.write(temporary_path, contents + "\n")
      File.rename(temporary_path, path)
      path
    end
    
    private def print_report(machine_report_path : String) : Nil
      puts
      puts "#{@name} smoke test"
      puts "=" * 72
      puts "Original session: #{@origin_session_name}"
      puts "Smoke-test session: #{@session_name || "(not created)"}"
      puts
    
      @report.each do |check|
        marker = check[:passed] ? "\e[32mPASS\e[0m" : "\e[31mFAIL\e[0m"
        duration = "#{check[:duration_ms].round(0)} ms"
        details = check[:details]
        summary = details.empty? ? duration : "#{duration}; #{details}"
        puts "#{marker}  #{check[:name]} (#{summary})"
      end
    
      puts
      if name = @session_name
        if @session_cleaned
          puts "The temporary smoke-test session was cleaned up: #{name}"
        else
          puts "The smoke-test session was left open: #{name}"
          puts "Return to it with: tmux switch-client -t '#{name}'"
        end
      else
        puts "No smoke-test session was created."
      end
      puts "Machine-readable report: #{machine_report_path}"
    end

    abstract class Scenario < Testing
      def execute_steps : Nil
        run_steps
      end

      def run_steps : Nil
      end

      macro step(name, &block)
        def run_steps : Nil
          previous_def
          record_step({{name}}) do
            {{block.body}}
          end
        end
      end
    end
  end
end