def step(name : String, &block : -> T) : Nil forall T
  record_step(name) { yield }
end

private def record_step(name : String, &block : -> T) : Nil forall T
  started_at = Time.instant
  @stage = name

  begin
    yield
    @report << {
      name: name,
      passed: true,
      duration_ms: (Time.instant - started_at).total_milliseconds,
      details: "",
    }
    sleep @step_delay if @step_delay.total_nanoseconds > 0
  rescue ex
    @report << {
      name: name,
      passed: false,
      duration_ms: (Time.instant - started_at).total_milliseconds,
      details: "#{ex.class}: #{ex.message}",
    }
    raise ex
  end
end
