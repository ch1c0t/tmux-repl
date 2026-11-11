@events : AMQP::Client::Queue?
@commands : AMQP::Client::Queue?
@consumer_tag : String?
@state_mutex : Mutex
@processing_finished : Channel(Nil)
@processing = false

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
  @processing_finished = Channel(Nil).new(1)
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
    accepted = @state_mutex.synchronize do
      if @stopped
        false
      else
        @processing = true
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
      @state_mutex.synchronize { @processing = false }
      select
      when @processing_finished.send(nil)
      else
        nil
      end
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

  processing = @state_mutex.synchronize { @processing }

  begin
    if commands = @commands
      if consumer_tag = @consumer_tag
        commands.unsubscribe(consumer_tag)
        @consumer_tag = nil
      end
    end
  ensure
    begin
      @processing_finished.receive if processing
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
