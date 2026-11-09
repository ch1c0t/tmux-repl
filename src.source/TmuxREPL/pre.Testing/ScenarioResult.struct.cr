getter name : String
getter status : Symbol
getter duration_ms : Float64
getter report_path : String?
getter details : String?

def initialize(
  @name : String,
  @status : Symbol,
  @duration_ms : Float64,
  @report_path : String?,
  @details : String?
)
end

def passed? : Bool
  @status == :passed
end

def failed? : Bool
  @status == :failed
end

def skipped? : Bool
  @status == :skipped
end
