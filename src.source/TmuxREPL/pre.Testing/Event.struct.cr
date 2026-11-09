getter type : String
getter sequence : Int64
getter chunk : String?
getter status : Int32?
getter clean_output : String?

def initialize(
  @type : String,
  @sequence : Int64,
  @chunk : String?,
  @status : Int32?,
  @clean_output : String?
)
end
