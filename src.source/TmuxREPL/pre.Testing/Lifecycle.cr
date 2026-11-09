def initialize(
  @name : String,
  configuration : Configuration
)
  unless ENV["TMUX"]? && ENV["TMUX_PANE"]?
    raise "Run this smoke test from inside the Tmux session to return to."
  end

  @configuration = configuration
  @cleanup = configuration.cleanup
  @focus = configuration.focus
  @restore_client = configuration.restore_client
  @step_delay = configuration.step_delay
  @timeout = configuration.timeout
  @start_timeout = configuration.start_timeout
  @host_stop_timeout = configuration.host_stop_timeout

  @server = Tmux::Server.from_env
  @origin_session = Tmux::Session.from_env
  @origin_session_name = @origin_session.session_name
  @started_at = Time.utc
end

getter timeout : Time::Span

def run(&scenario : Testing ->) : Nil
  run_result { |runner| yield runner }
  raise @failure.not_nil! if @failure
end

def run_result(&scenario : Testing ->) : ScenarioResult
  started_at = Time.instant

  begin
    yield self
  rescue ex
    @failure = ex
    last = @report.last?
    unless last && !last[:passed]
      @report << {
        name: "Smoke test",
        passed: false,
        duration_ms: 0.0,
        details: "#{@stage}: #{ex.class}: #{ex.message}",
      }
    end
  ensure
    finish
  end

  report_path = write_machine_report
  print_report(report_path)

  ScenarioResult.new(
    @name,
    @report.all? { |check| check[:passed] } ? :passed : :failed,
    (Time.instant - started_at).total_milliseconds,
    report_path,
    @failure.try { |exception| "#{exception.class}: #{exception.message}" }
  )
end
