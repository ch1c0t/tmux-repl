getter name : String

@command : Array(String)?
@environment : Hash(String, String)
@start_directory : String?
@input_executable : String?
@output_executable : String?
@worker_executable : String?
@handlers : Hash(String, Proc(CommandContext, Array(String), Nil))
@host : CustomCommandHost?

def initialize(@name : String)
  @command = nil
  @environment = {} of String => String
  @start_directory = nil
  @input_executable = nil
  @output_executable = nil
  @worker_executable = nil
  @handlers = {} of String => Proc(CommandContext, Array(String), Nil)
  @host = nil
end

# Configure a native interactive program for this REPL.
# With no command or custom handlers, the standard shell/PTY worker is used.
def command(*arguments : String) : self
  configure_command(arguments.to_a)
end

def command(arguments : Array(String)) : self
  configure_command(arguments)
end

# Register an application command. Handlers run in the process that owns this
# Definition, not in the separate PTY worker.
def on_command(
  name : String,
  &handler : CommandContext, Array(String) -> Nil
) : self
  raise ArgumentError.new("Cannot register custom commands with a native REPL command") if @command
  unless name.match(/\A[a-zA-Z][a-zA-Z0-9_-]*\z/)
    raise ArgumentError.new("Invalid custom command name: #{name.inspect}")
  end
  raise ArgumentError.new("Custom command #{name.inspect} is already registered") if @handlers.has_key?(name)

  @handlers[name] = handler
  self
end

def command_names : Array(String)
  @handlers.keys.sort
end

def custom_commands? : Bool
  !@handlers.empty?
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
  raise ArgumentError.new("A REPL cannot combine a native command with custom handlers") if @command && custom_commands?

  Session.new(
    @name,
    command: @command,
    environment: @environment,
    start_directory: @start_directory,
    input_executable: @input_executable,
    output_executable: @output_executable,
    worker_executable: @worker_executable,
    custom_command_mode: custom_commands?
  )
end

def start(focus : Bool = true) : Session
  raise "Custom REPL is already started" if @host

  repl_session = session
  if custom_commands?
    @host = CustomCommandHost.new(@name, @handlers.dup)
    @host.not_nil!.start
  end

  repl_session.start(focus)
  repl_session
rescue ex
  @host.try &.stop
  @host = nil
  raise ex
end

# Block the application process while the custom REPL session is alive.
# The command consumer is connected by start before the input pane is exposed.
def serve : Nil
  host = @host || raise "No custom command host is active; register commands and call start first."
  begin
    host.wait
  ensure
    @host = nil
  end
end

def stop : Nil
  @host.try &.stop
  session.stop
end

private def configure_command(arguments : Array(String)) : self
  raise ArgumentError.new("REPL command must not be empty") if arguments.empty?
  raise ArgumentError.new("Cannot configure a native command after registering custom handlers") if custom_commands?

  @command = arguments.dup
  self
end
