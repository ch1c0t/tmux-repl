getter name : String

@command : Array(String)?
@environment : Hash(String, String)
@start_directory : String?
@input_executable : String?
@output_executable : String?
@worker_executable : String?

def initialize(@name : String)
  @command = nil
  @environment = {} of String => String
  @start_directory = nil
  @input_executable = nil
  @output_executable = nil
  @worker_executable = nil
end

# Configure a native interactive program for this REPL.
# With no command configured, the standard shell/PTY worker is used.
def command(*arguments : String) : self
  configure_command(arguments.to_a)
end

def command(arguments : Array(String)) : self
  configure_command(arguments)
end

def env(name : String, value : String) : self
  @environment[name] = value
  self
end

def env(values : Hash(String, String)) : self
  @environment.merge!(values)
  self
end

def cwd(path : String) : self
  @start_directory = path
  self
end

# Override any of the companion processes independently. Unspecified
# executables continue to use the normal sibling/PATH discovery.
def executables(
  input : String? = nil,
  output : String? = nil,
  worker : String? = nil
) : self
  @input_executable = input unless input.nil?
  @output_executable = output unless output.nil?
  @worker_executable = worker unless worker.nil?
  self
end

def session : Session
  Session.new(
    @name,
    command: @command,
    environment: @environment,
    start_directory: @start_directory,
    input_executable: @input_executable,
    output_executable: @output_executable,
    worker_executable: @worker_executable
  )
end

def start(focus : Bool = true) : Session
  repl_session = session
  repl_session.start(focus)
  repl_session
end

def stop : Nil
  session.stop
end

private def configure_command(arguments : Array(String)) : self
  raise ArgumentError.new("REPL command must not be empty") if arguments.empty?

  @command = arguments.dup
  self
end
