def initialize(@session_name : String, @tmux_session_id : String)
  @shutdown = Channel(Nil).new(1)
  @session = PTY::Session.new(:sh)

  @state = TmuxREPL::State.open(@session_name)
  @state_dir = @state.base_path
  @ready_path = File.join(@state_dir, "worker.pid")
  @startup_error_path = File.join(@state_dir, "worker.error")
  @startup_stage_path = File.join(@state_dir, "worker.startup")
end

def run : Nil
  prepare_startup
  install_shutdown_handler

  begin
    commands, events = connect
    start_pty
    subscribe(commands, events)
    server = tmux_server
    advertise_ready
    wait_for_tmux_session(server)
  rescue ex
    report_startup_error(ex)
    exit 1
  ensure
    cleanup
  end
end

include Lifecycle
include Messaging
include Command
