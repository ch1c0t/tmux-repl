getter name : String
getter command : Array(String)?
getter environment : Hash(String, String)
getter start_directory : String?

def initialize(
  @name : String,
  @command : Array(String)? = nil,
  @environment : Hash(String, String) = {} of String => String,
  @start_directory : String? = nil
)
  if command = @command
    raise ArgumentError.new("REPL command must not be empty") if command.empty?
  end
end

include Start
include Stop
include Helpers
