getter character : Char
getter action : Action?
getter pressed_at : Time
getter monotonic_at : Time::Instant

def initialize(@character : Char, @action : Action?)
  @monotonic_at = Time.instant
  @pressed_at = Time.utc
end
