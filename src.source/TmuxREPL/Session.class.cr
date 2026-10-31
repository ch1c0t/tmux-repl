getter name : String
getter command : Array(String)?
getter environment : Hash(String, String)
getter start_directory : String?

# Resolve companion executables against the directory containing the invoking
# tmux.repl executable, then against the caller's PATH.
module CompanionExecutable
  def self.resolve(
    name : String,
    program_path : String,
    search_path : String? = ENV["PATH"]?
  ) : String
    program_path = File.expand_path(program_path)
    sibling = File.join(File.dirname(program_path), name)
    return sibling if File::Info.executable?(sibling)

    if search_path
      search_path.split(':').each do |directory|
        directory = "." if directory.empty?
        candidate = File.expand_path(name, directory)
        return candidate if File::Info.executable?(candidate)
      end
    end

    raise "Cannot find executable #{name.inspect} beside #{program_path.inspect} or on PATH"
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
