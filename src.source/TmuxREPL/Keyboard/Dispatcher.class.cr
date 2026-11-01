@queue : Queue(KeyPress)
@state_mutex : Sync::Mutex
@finished : Channel(Nil)
@trace : Trace
@started = false
@stopped = false
@joined = false

def initialize(
  @session_name : String,
  @pane : String,
  @events : AMQP::Client::Queue
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
  press = KeyPress.new(character, action)

  @state_mutex.synchronize do
    @queue.push(press) unless @stopped
  end

  action
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
           else
             @pane == "input" ? "handled_by_reply" : "ignored"
           end

  @trace.record(press, action_name, result)
end
