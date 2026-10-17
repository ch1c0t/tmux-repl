getter binary : String

def initialize(binary : String = "tmux", socket_name : String? = nil, socket_path : String? = nil)
  raise Error.new("Specify socket_name or socket_path, not both") if socket_name && socket_path

  @binary = binary
  @server_options = [] of String
  @server_options.concat(["-L", socket_name]) if socket_name
  @server_options.concat(["-S", socket_path]) if socket_path
end

include Run

def interactive!(*args : String) : Nil
  status = Process.run(@binary, @server_options + args.to_a)
  raise Error.new("tmux command failed (#{status.exit_code})") unless status.success?
rescue ex
  raise ex if ex.is_a?(Error)
  raise Error.new("Unable to execute #{@binary}: #{ex.message || ex.class.name}")
end
