class Reader < Reply::Reader
  @ready_path : String

  def initialize(@ready_path : String)
    super()
  end

  def prompt(io : IO, line_number : Int32, color : Bool)
    super(io, line_number, color)
    File.write(@ready_path, Process.pid.to_s) unless File.exists?(@ready_path)
  end
end
