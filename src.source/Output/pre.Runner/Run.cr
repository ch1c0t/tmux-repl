# Connect to the event stream, render its events, and stay alive with the tmux session.
def run : Nil
  prepare_startup
  event_queue : AMQP::Client::Queue? = nil
  consumer_tag : String? = nil

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

    view.render
    mark_ready
    shutdown.receive
  rescue ex
    report_startup_failure(ex)
    exit 1
  ensure
    unsubscribe(event_queue, consumer_tag)
    cleanup_readiness
  end
end
