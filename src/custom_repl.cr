require "file_utils"
require "json"
require "global-amqp_channel"
require "tmux"

module CustomREPL
  # Application-owned command execution for custom Tmux REPLs.

  class CommandContext
    @output = String::Builder.new
    
    def initialize(
      @session_name : String,
      @sequence : UInt64,
      @events : AMQP::Client::Queue
    )
    end
    
    # Publish a chunk immediately so long-running handlers can stream progress.
    def write(chunk : String) : Nil
      return if chunk.empty?
    
      @output << chunk
      Protocol.publish_event(
        @events,
        "output",
        @session_name,
        @sequence,
        chunk: chunk
      )
    end
    
    def puts(value : String = "") : Nil
      write("#{value}\n")
    end
    
    def output : String
      @output.to_s
    end
    
  end

  module CommandLine
    # Tokenize a custom command without invoking a shell.
    # Single/double quotes group arguments; backslash escapes outside single quotes.
    def self.parse(line : String) : Array(String)
      arguments = [] of String
      token = String::Builder.new
      token_started = false
      quote : Char? = nil
      escaped = false
    
      line.each_char do |character|
        if escaped
          token << character
          escaped = false
          token_started = true
        elsif quote == '\''
          if character == '\''
            quote = nil
          else
            token << character
          end
        elsif quote == '"'
          case character
          when '"'
            quote = nil
          when '\\'
            escaped = true
          else
            token << character
          end
        elsif character == '\'' || character == '"'
          quote = character
          token_started = true
        elsif character == '\\'
          escaped = true
          token_started = true
        elsif character.whitespace?
          if token_started
            arguments << token.to_s
            token = String::Builder.new
            token_started = false
          end
        else
          token << character
          token_started = true
        end
      end
    
      raise ArgumentError.new("Trailing escape in command") if escaped
      raise ArgumentError.new("Unterminated quote in command") if quote
    
      arguments << token.to_s if token_started
      arguments
    end
    
  end

  class CustomCommandHost
    @events : AMQP::Client::Queue?
    
    def initialize(
      @session_name : String,
      @state_path : String,
      @handlers : Hash(String, Proc(CommandContext, Array(String), Nil))
    )
      @shutdown = Channel(Nil).new(1)
      @stopped = false
      @events = nil
    end
    
    # Connect before the input pane is started so its first command cannot race
    # the stream consumer's subscription.
    def start : Nil
      channel = Global.amqp_channel
      channel.prefetch(1)
    
      commands = Protocol.stream_queue(
        channel,
        Protocol.commands_queue_name(@session_name)
      )
      @events = Protocol.stream_queue(
        channel,
        Protocol.events_queue_name(@session_name)
      )
    
      commands.subscribe(
        no_ack: false,
        block: false,
        args: AMQ::Protocol::Table.new(
          {"x-stream-offset" => "next"} of String => AMQ::Protocol::Field
        )
      ) do |message|
        begin
          data = JSON.parse(message.body_io.to_s)
          process_message(data) if data["type"].as_s == "command"
          message.ack
        rescue ex
          STDERR.puts "tmux.repl custom host: command failed: #{ex.class}: #{ex.message}"
          begin
            message.reject(requeue: false)
          rescue
          end
        end
      end
    end
    
    # Keep the application process alive while its custom Tmux session exists.
    def wait : Nil
      server = ENV["TMUX"]?.nil? ? Tmux::Server.new : Tmux::Server.from_env
      tmux_session = server.session(@session_name)
      tmux_session_id = tmux_session.session_id
    
      loop do
        break unless server.cmd("has-session", "-t", tmux_session_id).success?
    
        select
        when @shutdown.receive
          break
        when timeout(250.milliseconds)
        end
      end
    ensure
      @stopped = true
    end
    
    def stop : Nil
      return if @stopped
    
      @shutdown.send(nil)
    end
    
    private def process_message(data : JSON::Any) : Nil
      sequence = data["sequence"].as_i64.to_u64
      command = data["command"].as_s
      session_name = data["session"].as_s
      raise "Command belongs to #{session_name.inspect}, not #{@session_name.inspect}" unless session_name == @session_name
    
      events = @events || raise "Custom command host has not been started."
      received_at = Time.instant
      Protocol.trace_timing(
        @session_name,
        @state_path,
        "command_received",
        details: "sequence=#{sequence} command_bytes=#{command.bytesize}"
      )
    
      Protocol.publish_event(events, "started", @session_name, sequence, command: command)
      context = CommandContext.new(@session_name, sequence, events)
      status = 0
    
      begin
        arguments = CommandLine.parse(command)
        if arguments.empty?
          context.puts("Empty command.")
          status = 2
        elsif handler = @handlers[arguments.first]?
          handler.call(context, arguments[1, arguments.size - 1])
        else
          context.puts("Unknown command: #{arguments.first}")
          status = 127
        end
      rescue ex
        context.puts("Error: #{ex.message || ex.class}")
        status = 1
      end
    
      Protocol.publish_event(
        events,
        "complete",
        @session_name,
        sequence,
        command: command,
        status: status,
        clean_output: context.output
      )
      Protocol.trace_timing(
        @session_name,
        @state_path,
        "command_processing_finished",
        received_at,
        "sequence=#{sequence} status=#{status}"
      )
    end
    
  end

  class FixtureBackend
    def latest_ocr : String
      "SCREEN OCR: fixture display is ready"
    end

    def send_key(action : String, key : String) : String
      "KEY EVENT: #{action} #{key}"
    end
  end

  module Protocol
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
    
    def self.stream_queue(
      channel : AMQP::Client::Channel,
      name : String
    ) : AMQP::Client::Queue
      channel.queue(name, args: AMQP::Client::Arguments.new({"x-queue-type": "stream"}))
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
    
    def self.trace_timing(
      session_name : String,
      state_path : String,
      event : String,
      started_at : Time::Instant? = nil,
      details : String = ""
    ) : Nil
      return unless ENV["TMUX_REPL_TRACE_TIMING"]? == "1"
    
      trace_path = ENV["TMUX_REPL_TRACE_FILE"]? || File.join(state_path, "logs", "timing.log")
      FileUtils.mkdir_p(File.dirname(trace_path))
    
      elapsed = if start = started_at
        " elapsed_ms=#{(Time.instant - start).total_milliseconds.round(2)}"
      else
        ""
      end
      detail_suffix = details.empty? ? "" : " #{details}"
    
      File.open(trace_path, "a") do |file|
        file.puts "#{Time.utc} [custom] #{session_name} #{event}#{elapsed}#{detail_suffix}"
      end
    rescue
      # Diagnostic tracing must never interfere with command execution.
    end
    
  end

  class SmokeTest
    TIMEOUT = 8.seconds

    @server : Tmux::Server
    @origin_session : Tmux::Session
    @origin_session_name : String
    @session_name : String
    @process : Process?
    @input_pane : Tmux::Pane?
    @output_pane : Tmux::Pane?
    @checks = 0

    def initialize
      unless ENV["TMUX"]? && ENV["TMUX_PANE"]?
        raise "Run tmux.repl.custom_repl.test from inside the Tmux session to return to."
      end

      @server = Tmux::Server.from_env
      @origin_session = Tmux::Session.from_env
      @origin_session_name = @origin_session.session_name
      @session_name = "tmux-repl-custom-test-#{Process.pid}-#{Time.utc.to_unix_ms}"
      @process = nil
      @input_pane = nil
      @output_pane = nil
    end

    def run : Nil
      failure : Exception? = nil

      begin
        start_fixture
        attach_panes
        check(
          "ocr",
          ["INPUT #1", "SCREEN OCR: fixture display is ready", "[exit status: 0]"]
        )
        check(
          "key press Escape",
          ["INPUT #2", "KEY EVENT: press Escape", "[exit status: 0]"]
        )
        check(
          %(echo "hello world"),
          ["INPUT #3", "hello world", "[exit status: 0]"]
        )
        check(
          "missing",
          ["INPUT #4", "Unknown command: missing", "[exit status: 127]"]
        )
        check(
          "fail",
          ["INPUT #5", "Error: fixture failure", "[exit status: 1]"]
        )
      rescue ex
        failure = ex
      ensure
        begin
          cleanup
        rescue ex
          if failure
            STDERR.puts "tmux.repl.custom_repl.test cleanup: #{ex.message}"
          else
            failure = ex
          end
        end
      end

      raise failure.not_nil! if failure

      puts
      puts "tmux.repl.custom_repl smoke test: #{@checks} checks passed."
    end

    private def start_fixture : Nil
      executable = File.join(File.dirname(File.expand_path(PROGRAM_NAME)), "tmux.repl.custom_repl")
      raise "Missing #{executable}. Build the executables first with shards build." unless File::Info.executable?(executable)

      environment = {} of String => String?
      ENV.each { |key, value| environment[key] = value }
      environment["TMUX_REPL_SESSION"] = @session_name

      @process = Process.new(
        executable,
        [] of String,
        env: environment,
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )

      ready = wait_until do
        session_exists = @server.sessions.any? { |candidate| candidate.session_name == @session_name }
        session_exists && current_client_session_name == @session_name
      end

      unless ready
        current = current_client_session_name || "(unavailable)"
        raise "Custom REPL session #{@session_name.inspect} did not become the foreground session (current client session: #{current.inspect})."
      end
    end

    private def attach_panes : Nil
      ensure_foreground!

      session = @server.session(@session_name)
      panes = session.active_window.panes
      raise "Expected two panes, found #{panes.size}." unless panes.size == 2

      @input_pane = panes[0]
      @output_pane = panes[1]
      @checks += 1
      puts "PASS  Custom REPL session is focused with two panes"
    end

    private def check(command : String, expected : Array(String)) : Nil
      input_pane.send_keys(command, literal: true)
      last_text = ""
      found = wait_until do
        last_text = pane_text(output_pane)
        expected.all? { |text| last_text.includes?(text) }
      end
      unless found
        missing = expected.reject { |text| last_text.includes?(text) }
        raise "Command #{command.inspect} did not produce #{missing.map(&.inspect).join(", ")}.\n#{last_text}"
      end

      ensure_foreground!
      @checks += 1
      puts "PASS  #{command}"
    end

    private def ensure_foreground! : Nil
      current = current_client_session_name
      raise "Expected the foreground Tmux session to be #{@session_name.inspect}, got #{current.inspect}." unless current == @session_name
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

    private def wait_until(&condition : -> Bool) : Bool
      deadline = Time.instant + TIMEOUT
      while Time.instant < deadline
        return true if yield
        sleep 25.milliseconds
      end
      yield
    end

    private def pane_text(pane : Tmux::Pane) : String
      pane.capture_pane(join_wrapped: true).join("\n")
    end

    private def input_pane : Tmux::Pane
      @input_pane || raise "Input pane is not available."
    end

    private def output_pane : Tmux::Pane
      @output_pane || raise "Output pane is not available."
    end

    private def cleanup : Nil
      errors = [] of String

      # Switch back while the custom session still exists. Killing the session
      # while it is active can detach the client before it can be restored.
      begin
        @origin_session.switch_client
        restored = wait_until { current_client_session_name == @origin_session_name }
        raise "The Tmux client did not return to #{@origin_session_name.inspect}." unless restored

        @checks += 1
        puts "PASS  Return to original session #{@origin_session_name}"
      rescue ex
        errors << "Could not return to original Tmux session: #{ex.message}"
      end

      begin
        if @server.cmd("has-session", "-t", @session_name).success?
          result = @server.cmd("kill-session", "-t", @session_name)
          unless result.success?
            errors << "Could not kill custom Tmux session #{@session_name.inspect}."
            terminate_host
          end
        end
      rescue ex
        errors << "Could not remove custom Tmux session: #{ex.message}"
        terminate_host
      end

      if process = @process
        begin
          status = process.wait
          errors << "Custom REPL host exited with status #{status.exit_code}." unless status.success?
        rescue ex
          errors << "Could not wait for custom REPL host: #{ex.message}"
        end
      end

      raise errors.join("\n") unless errors.empty?
    end

    private def terminate_host : Nil
      if process = @process
        Process.signal(Signal::TERM, process.pid)
      end
    rescue
    end
  end

end
