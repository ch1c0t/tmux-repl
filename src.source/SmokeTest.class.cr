TIMEOUT = 8.seconds

@server : Tmux::Server
@origin_session : Tmux::Session
@origin_session_name : String
@repl_session : Tmux::Session?
@repl_session_name : String?
@input_pane : Tmux::Pane?
@output_pane : Tmux::Pane?
@step_delay : Time::Span
@started_at : Time
@stage = "initialize"
@report = [] of NamedTuple(
  name: String,
  passed: Bool,
  duration_ms: Float64,
  details: String
)

def initialize
  unless ENV["TMUX"]? && ENV["TMUX_PANE"]?
    raise "Run ./bin/tmux.repl.test from inside the tmux session you want to return to."
  end

  @server = Tmux::Server.from_env
  @origin_session = Tmux::Session.from_env
  @origin_session_name = @origin_session.session_name
  @started_at = Time.utc

  delay = ENV["TMUX_REPL_TEST_DELAY"]?.try(&.to_f?) || 0.8
  delay = 0.0 if delay < 0
  @step_delay = delay.seconds
end

include Private
include Run
