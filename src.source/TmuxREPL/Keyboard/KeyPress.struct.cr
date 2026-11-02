  getter character : Char
  getter key : String?
  getter action : Action?
  getter pressed_at : Time
  getter monotonic_at : Time::Instant

  def initialize(@character : Char, @action : Action?)
    @key = nil
    @monotonic_at = Time.instant
    @pressed_at = Time.utc
  end

  def initialize(@key : String, @action : Action)
    @character = '\0'
    @monotonic_at = Time.instant
    @pressed_at = Time.utc
  end
