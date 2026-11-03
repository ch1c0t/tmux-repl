require "file_utils"
require "json"
require "tmux"
require "global-amqp_channel"
require "queue"

module TmuxREPL
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
  
  def self.publish_message(
    queue : AMQP::Client::Queue,
    type : String,
    session_name : String,
    sequence : UInt64,
    command : String? = nil,
    chunk : String? = nil,
    status : Int32? = nil,
    clean_output : String? = nil
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
      end
    end
    properties = AMQP::Client::Properties.new(delivery_mode: 2)
    raise "LavinMQ did not confirm publish to stream #{queue.name}" unless queue.publish_confirm(payload, props: properties)
  end
  
  def self.publish_event(
    queue : AMQP::Client::Queue,
    type : String,
    session_name : String,
    sequence : UInt64,
    command : String? = nil,
    chunk : String? = nil,
    status : Int32? = nil,
    clean_output : String? = nil
  ) : Nil
    publish_message(queue, type, session_name, sequence, command, chunk, status, clean_output)
  end
  
  def self.publish_command(
    queue : AMQP::Client::Queue,
    session_name : String,
    sequence : UInt64,
    command : String
  ) : Nil
    publish_message(queue, "command", session_name, sequence, command: command)
  end
  
  # Optional timing diagnostics for tracing command latency across the separate
  # input, worker, and output processes. Disabled unless explicitly requested.
  def self.trace_timing_enabled? : Bool
    ENV["TMUX_REPL_TRACE_TIMING"]? == "1"
  end
  
  def self.trace_timing(
    session_name : String,
    component : String,
    event : String,
    started_at : Time::Instant? = nil,
    details : String = ""
  ) : Nil
    return unless trace_timing_enabled?
  
    trace_path = ENV["TMUX_REPL_TRACE_FILE"]?
    unless trace_path
      base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
      trace_path = File.join(base, "tmux-repl", session_name, "timing.log")
    end
  
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

  class Definition
    getter name : String
    
    @command : Array(String)?
    @environment : Hash(String, String)
    @start_directory : String?
    @input_executable : String?
    @output_executable : String?
    @worker_executable : String?
    
    def initialize(@name : String)
      @command = nil
      @environment = {} of String => String
      @start_directory = nil
      @input_executable = nil
      @output_executable = nil
      @worker_executable = nil
    end
    
    # Configure a native interactive program for this REPL.
    # With no command configured, the standard shell/PTY worker is used.
    def command(*arguments : String) : self
      configure_command(arguments.to_a)
    end
    
    def command(arguments : Array(String)) : self
      configure_command(arguments)
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
      Session.new(
        @name,
        command: @command,
        environment: @environment,
        start_directory: @start_directory,
        input_executable: @input_executable,
        output_executable: @output_executable,
        worker_executable: @worker_executable
      )
    end
    
    def start(focus : Bool = true) : Session
      repl_session = session
      repl_session.start(focus)
      repl_session
    end
    
    def stop : Nil
      session.stop
    end
    
    private def configure_command(arguments : Array(String)) : self
      raise ArgumentError.new("REPL command must not be empty") if arguments.empty?
    
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
      SelectPrevious
      SelectNext
      SubmitInput
      ScrollUp
      ScrollDown
      ScrollPageUp
      ScrollPageDown
    end
    
    struct Binding
      getter key : Char
      getter action : Action
      getter label : String
      getter description : String
    
      def initialize(@key : Char, @action : Action, @label : String, @description : String)
      end
    
      def help_line : String
        "#{label.ljust(12)}#{description}"
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
        "#{label.ljust(12)}#{description}"
      end
    end
    
    BINDINGS = [
      Binding.new(
        '\u0007',
        Action::ToggleOutputView,
        "Ctrl+G",
        "Toggle stripped/raw output from either pane."
      ),
    ]
    
    # Ctrl+Up/Down are the primary bindings. Alt+K/J are aliases.
    SEQUENCE_BINDINGS = [
      SequenceBinding.new("Ctrl+Up", Action::SelectPrevious, "Ctrl+Up", "Select the previous input."),
      SequenceBinding.new("Ctrl+Down", Action::SelectNext, "Ctrl+Down", "Select the next input."),
      SequenceBinding.new("Alt+K", Action::SelectPrevious, "Alt+K", "Also select the previous input."),
      SequenceBinding.new("Alt+J", Action::SelectNext, "Alt+J", "Also select the next input."),
    ]
    
    # These escape sequences are only consumed by the output-pane keyboard reader.
    OUTPUT_SEQUENCE_BINDINGS = {
      "\e[A"  => SequenceBinding.new("Up", Action::ScrollUp, "Up", "Scroll output up one line."),
      "\e[B"  => SequenceBinding.new("Down", Action::ScrollDown, "Down", "Scroll output down one line."),
      "\e[5~" => SequenceBinding.new("PageUp", Action::ScrollPageUp, "PageUp", "Scroll output up one page."),
      "\e[6~" => SequenceBinding.new("PageDown", Action::ScrollPageDown, "PageDown", "Scroll output down one page."),
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
      (BINDINGS.map(&.help_line) + SEQUENCE_BINDINGS.map(&.help_line)).join("\n")
    end
  
    class InputIO(T) < IO
      @source_buffer = Bytes.new(8192)
      @read_buffer = Bytes.new(8192 * 3)
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
      
        refill if @source_offset >= @source_size
        return 0 if @eof
      
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
      
      # Reply reports both native Ctrl arrows and translated Alt aliases through its
      # existing Ctrl+Up/Down callbacks. Keep the original binding for diagnostics.
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
      
      private def refill : Nil
        raw_size = @source.read(@source_buffer)
        @source_offset = 0
        @source_size = translate_navigation_sequences(raw_size)
        @eof = raw_size == 0
      end
      
      # Translate Alt+K/J into the Ctrl+Up/Down sequences understood by Reply 0.4.
      # Both ESC-prefixed terminal input and Kitty CSI-u input are accepted.
      private def translate_navigation_sequences(raw_size : Int32) : Int32
        input_offset = 0
        output_size = 0
      
        while input_offset < raw_size
          if sequence = alt_navigation_sequence(input_offset, raw_size)
            binding, input_size = sequence
            @navigation_bindings << binding
      
            translated = binding.action == Action::SelectPrevious ? "\e[1;5A" : "\e[1;5B"
            output_size += append_sequence(translated, output_size)
            input_offset += input_size
          elsif binding = control_navigation_binding(input_offset, raw_size)
            @navigation_bindings << binding
            sequence_size = "\e[1;5A".bytesize
            @read_buffer[output_size, sequence_size].copy_from(@source_buffer[input_offset, sequence_size])
            output_size += sequence_size
            input_offset += sequence_size
          else
            @read_buffer[output_size] = @source_buffer[input_offset]
            output_size += 1
            input_offset += 1
          end
        end
      
        output_size
      end
      
      private def alt_navigation_sequence(offset : Int32, limit : Int32) : Tuple(SequenceBinding, Int32)?
        if matches?(@source_buffer, offset, limit, "\ek")
          {TmuxREPL::Keyboard.sequence_binding_for("Alt+K").not_nil!, 2}
        elsif matches?(@source_buffer, offset, limit, "\ej")
          {TmuxREPL::Keyboard.sequence_binding_for("Alt+J").not_nil!, 2}
        elsif matches?(@source_buffer, offset, limit, "\e[107;3u")
          {TmuxREPL::Keyboard.sequence_binding_for("Alt+K").not_nil!, 8}
        elsif matches?(@source_buffer, offset, limit, "\e[106;3u")
          {TmuxREPL::Keyboard.sequence_binding_for("Alt+J").not_nil!, 8}
        end
      end
      
      private def control_navigation_binding(offset : Int32, limit : Int32) : SequenceBinding?
        if matches?(@source_buffer, offset, limit, "\e[1;5A")
          TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Up")
        elsif matches?(@source_buffer, offset, limit, "\e[1;5B")
          TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Down")
        end
      end
      
      private def append_sequence(sequence : String, offset : Int32) : Int32
        bytes = sequence.to_slice
        @read_buffer[offset, bytes.size].copy_from(bytes)
        bytes.size
      end
      
      private def matches?(buffer : Bytes, offset : Int32, limit : Int32, sequence : String) : Bool
        bytes = sequence.to_slice
        return false if offset + bytes.size > limit
      
        bytes.size.times do |index|
          return false unless buffer[offset + index] == bytes[index]
        end
        true
      end
      
      # Keep Enter and each navigation sequence in a separate read so Reply sees them
      # even when ordinary text or another key arrived in the same OS read.
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
        base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
        session = ENV["TMUX_REPL_SESSION_NAME"]? || session_name
        File.join(base, "tmux-repl", session, "keyboard.trace.log")
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
                 when Action::SelectPrevious, Action::SelectNext
                   "handled_by_input_reader"
                 when Action::ScrollUp, Action::ScrollDown, Action::ScrollPageUp, Action::ScrollPageDown
                   @on_action.try &.call(action.not_nil!)
                   "handled_by_output_view"
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
          environment["TMUX_REPL_TRACE_FILE"] = File.join(state_dir, "timing.log")
        end
        environment
      end
      
      private def state_dir : String
        base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
        File.join(base, "tmux-repl", @name)
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
            FileUtils.mkdir_p(dir)
            unless @command
              File.write(File.join(dir, "input.startup"), "launching #{resolved_input_executable}")
            end
        
            created = if @command
              File.write(File.join(dir, "output.log"), "")
              server.new_session(
                name: @name,
                detached: true,
                start_directory: @start_directory,
                environment: @environment
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
        
            unless @command
              wait_for_ready(File.join(dir, "input.pid"), resolved_input_executable)
              File.write(File.join(dir, "worker.startup"), "launching #{resolved_worker_executable}")
              worker_process = Process.new(
                resolved_worker_executable,
                ["--worker", @name, created.session_id],
                input: Process::Redirect::Close,
                output: Process::Redirect::Close,
                error: Process::Redirect::Close
              )
              wait_for_ready(File.join(dir, "worker.pid"), resolved_worker_executable)
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
            File.write(File.join(state_dir, "output.startup"), "launching #{resolved_output_executable}")
            input_pane.split(
              :right,
              detached: true,
              command: [resolved_output_executable, @name]
            )
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
          FileUtils.rm_rf(dir)
        end
      end
    
      def start(focus : Bool = true) : Nil
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
          FileUtils.rm_rf(state_dir)
        end
      end
      
      private def stop_worker : Nil
        ready_path = File.join(state_dir, "worker.pid")
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
      @worker_executable : String? = nil
    )
      if command = @command
        raise ArgumentError.new("REPL command must not be empty") if command.empty?
      end
    end
    
    include Start
    include Stop
    include Helpers
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