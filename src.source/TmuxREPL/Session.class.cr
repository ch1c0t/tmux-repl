getter name : String
getter command : Array(String)?

def initialize(@name : String, @command : Array(String)? = nil)
  if command = @command
    raise ArgumentError.new("REPL command must not be empty") if command.empty?
  end
end

include Start
include Stop
include Helpers
