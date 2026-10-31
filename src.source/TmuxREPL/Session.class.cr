getter name : String
getter command : Array(String)?
getter environment : Hash(String, String)
getter start_directory : String?
getter input_executable : String?
getter output_executable : String?
getter worker_executable : String?

# Resolve companion executables in this order:
# explicit override, sibling of tmux.repl, then caller's PATH.
module CompanionExecutable
  def self.resolve(
    name : String,
    program_path : String,
    override : String? = nil,
    search_path : String? = ENV["PATH"]?
  ) : String
    if configured = override
      candidate = if configured.includes?('/')
        File.expand_path(configured)
      else
        find_on_path(configured, search_path)
      end

      return candidate if candidate && File::Info.executable?(candidate)

      raise "Configured executable override #{configured.inspect} for #{name.inspect} is not executable or could not be found on PATH"
    end

    program_path = File.expand_path(program_path)
    sibling = File.join(File.dirname(program_path), name)
    return sibling if File::Info.executable?(sibling)

    if candidate = find_on_path(name, search_path)
      return candidate
    end

    raise "Cannot find executable #{name.inspect} beside #{program_path.inspect} or on PATH"
  end

  private def self.find_on_path(name : String, search_path : String?) : String?
    return nil unless search_path

    search_path.split(':').each do |directory|
      directory = "." if directory.empty?
      candidate = File.expand_path(name, directory)
      return candidate if File::Info.executable?(candidate)
    end

    nil
  end
end

def initialize(
  @name : String,
  @command : Array(String)? = nil,
  @environment : Hash(String, String) = {} of String => String,
  @start_directory : String? = nil,
  @input_executable : String? = nil,
  @output_executable : String? = nil,
  @worker_executable : String? = nil
)
  if command = @command
    raise ArgumentError.new("REPL command must not be empty") if command.empty?
  end
end

include Start
include Stop
include Helpers
