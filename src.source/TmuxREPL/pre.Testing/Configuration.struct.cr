getter focus : Bool
getter cleanup : Symbol
getter restore_client : Bool
getter step_delay : Time::Span
getter timeout : Time::Span
getter start_timeout : Time::Span
getter host_stop_timeout : Time::Span

def initialize(
  @focus : Bool,
  @cleanup : Symbol,
  @restore_client : Bool,
  @step_delay : Time::Span,
  @timeout : Time::Span,
  @start_timeout : Time::Span,
  @host_stop_timeout : Time::Span
)
  unless @cleanup == :always || @cleanup == :never || @cleanup == :on_failure
    raise ArgumentError.new("cleanup must be always, never, or on_failure; got #{@cleanup.inspect}")
  end

  if @focus && @cleanup != :never && !@restore_client
    raise ArgumentError.new("restore_client must be enabled when a focused test session may be cleaned up")
  end
end

def self.from_env(
  name : String,
  focus : Bool,
  cleanup : Symbol,
  restore_client : Bool,
  step_delay : Time::Span,
  timeout : Time::Span,
  start_timeout : Time::Span,
  host_stop_timeout : Time::Span
) : self
  new(
    boolean(name, "FOCUS", focus),
    cleanup_policy(name, cleanup),
    boolean(name, "RESTORE_CLIENT", restore_client),
    duration(name, "DELAY", step_delay),
    duration(name, "TIMEOUT", timeout),
    duration(name, "START_TIMEOUT", start_timeout),
    duration(name, "HOST_STOP_TIMEOUT", host_stop_timeout)
  )
end

private def self.environment_value(name : String, setting : String) : String?
  scenario = (name.split('.').last? || name).gsub(/[^a-zA-Z0-9]/, "_").upcase
  full_name = name.gsub(/[^a-zA-Z0-9]/, "_").upcase

  ENV["TMUX_REPL_TEST_#{scenario}_#{setting}"]? ||
    ENV["TMUX_REPL_TEST_#{full_name}_#{setting}"]? ||
    ENV["TMUX_REPL_TEST_#{setting}"]?
end

private def self.boolean(name : String, setting : String, default : Bool) : Bool
  value = environment_value(name, setting)
  return default unless value

  case value.downcase
  when "1", "true", "yes", "on"
    true
  when "0", "false", "no", "off"
    false
  else
    raise ArgumentError.new("Invalid boolean for TMUX_REPL_TEST_#{setting}: #{value.inspect}")
  end
end

private def self.cleanup_policy(name : String, default : Symbol) : Symbol
  value = environment_value(name, "CLEANUP")
  return default unless value

  case value.downcase
  when "always"
    :always
  when "never"
    :never
  when "on_failure"
    :on_failure
  else
    raise ArgumentError.new("Invalid cleanup policy for TMUX_REPL_TEST_CLEANUP: #{value.inspect}")
  end
end

private def self.duration(name : String, setting : String, default : Time::Span) : Time::Span
  value = environment_value(name, setting)
  return default unless value

  seconds = value.to_f?
  unless seconds && seconds >= 0
    raise ArgumentError.new("Expected non-negative seconds for TMUX_REPL_TEST_#{setting}, got #{value.inspect}")
  end

  seconds.seconds
end
