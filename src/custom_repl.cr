require "file_utils"
require "mutex"
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
    @commands : AMQP::Client::Queue?
    @consumer_tag : String?
    @state_mutex : Mutex
    @processing_finished : Channel(Nil)?
    
    def initialize(
      @session_name : String,
      @state_path : String,
      @handlers : Hash(String, Proc(CommandContext, Array(String), Nil))
    )
      @shutdown = Channel(Nil).new(1)
      @stopped = false
      @events = nil
      @commands = nil
      @consumer_tag = nil
      @state_mutex = Mutex.new
      @processing_finished = nil
    end
    
    # Connect before the input pane is started so its first command cannot race
    # the stream consumer's subscription.
    def start : Nil
      raise "Custom command host is already started" if @commands
    
      channel = Global.amqp_channel
      channel.prefetch(1)
    
      @commands = Protocol.stream_queue(
        channel,
        Protocol.commands_queue_name(@session_name)
      )
      @events = Protocol.stream_queue(
        channel,
        Protocol.events_queue_name(@session_name)
      )
    
      @consumer_tag = @commands.not_nil!.subscribe(
        no_ack: false,
        block: false,
        args: AMQ::Protocol::Table.new(
          {"x-stream-offset" => "next"} of String => AMQ::Protocol::Field
        )
      ) do |message|
        finished = Channel(Nil).new(1)
        accepted = @state_mutex.synchronize do
          if @stopped
            false
          else
            @processing_finished = finished
            true
          end
        end
        next unless accepted
    
        begin
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
        ensure
          select
          when finished.send(nil)
          else
            nil
          end
          @state_mutex.synchronize { @processing_finished = nil }
        end
      end
    rescue ex
      stop
      raise ex
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
      stop
    end
    
    # Cancel the stream consumer and wake wait, including when Tmux closes the
    # session before the application asks the host to stop explicitly.
    def stop : Nil
      should_stop = @state_mutex.synchronize do
        if @stopped
          false
        else
          @stopped = true
          true
        end
      end
      return unless should_stop
    
      processing_finished = @state_mutex.synchronize { @processing_finished }
    
      begin
        if commands = @commands
          if consumer_tag = @consumer_tag
            commands.unsubscribe(consumer_tag)
            @consumer_tag = nil
          end
        end
      ensure
        begin
          processing_finished.try &.receive
        ensure
          select
          when @shutdown.send(nil)
          else
            nil
          end
        end
      end
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
end