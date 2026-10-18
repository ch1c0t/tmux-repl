getter name : String
getter command : Array(String)?

def initialize(@name : String, @command : Array(String)? = nil)
  raise ArgumentError.new("Invalid tmux session name") unless @name.matches?(/\A[a-zA-Z0-9_-]+\z/)
  raise ArgumentError.new("REPL command must not be empty") if @command.try(&.empty?)
end

def self.crystal_interpreter(name : String = "crystal", executable : String = "icr") : Session
  new(name, command: [executable])
end

include Start
include Stop
include Helpers
