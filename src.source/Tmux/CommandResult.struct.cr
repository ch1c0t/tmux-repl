getter args : Array(String)
getter stdout : String
getter stderr : String
getter exit_code : Int32

def initialize(@args : Array(String), @stdout : String, @stderr : String, @exit_code : Int32)
end

def success? : Bool
  @exit_code == 0
end

def stdout_lines : Array(String)
  @stdout.lines
end

def stderr_lines : Array(String)
  @stderr.lines
end
