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
      action : String? = nil
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
      action : String? = nil
    ) : Nil
      publish_message(queue, type, session_name, sequence, command, chunk, status, clean_output, action)
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
    @handlers : Hash(String, Proc(CommandContext, Array(String), Nil))
    @host : CustomCommandHost?
    
    def initialize(@name : String)
      @command = nil
      @environment = {} of String => String
      @start_directory = nil
      @input_executable = nil
      @output_executable = nil
      @worker_executable = nil
      @handlers = {} of String => Proc(CommandContext, Array(String), Nil)
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
      &handler : CommandContext, Array(String) -> Nil
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
        @host = CustomCommandHost.new(@name, @handlers.dup)
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
                     TmuxREPL.publish_event(@events, "toggle_output_zoom", @session_name, 0_u64)
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
end