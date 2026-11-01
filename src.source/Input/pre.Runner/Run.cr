# Connect to the streams, then read and dispatch user input.
def run : Nil
  prepare_startup
  keyboard : TmuxREPL::Keyboard::Dispatcher? = nil
  terminal_mode = TerminalMode.new

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
    reader = Reader.new(input_pid_path, keyboard)
    File.delete(startup_stage_path) if File.exists?(startup_stage_path)

    terminal_mode.enable
    history = TmuxREPL::InputHistory.new
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
