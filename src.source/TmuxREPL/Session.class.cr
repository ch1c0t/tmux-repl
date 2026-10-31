getter name : String
getter command : Array(String)?
getter environment : Hash(String, String)
getter start_directory : String?

# Resolve companion executables against the directory containing the invoking
# tmux.repl executable. A library host without sibling companions falls back to
# normal PATH lookup.
module CompanionExecutable
  def self.resolve(name : String, program_path : String) : String
    program_path = File.expand_path(program_path)
    sibling = File.join(File.dirname(program_path), name)
    return sibling if File::Info.executable?(sibling)

    name
  end
end

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
