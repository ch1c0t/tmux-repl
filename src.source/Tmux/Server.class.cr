getter client : Client

def initialize(socket_name : String? = nil, socket_path : String? = nil, binary : String = "tmux")
  @client = Client.new(binary, socket_name, socket_path)
end

def self.from_env(binary : String = "tmux") : Server
  value = ENV["TMUX"]? || raise NotInsideTmux.new("TMUX is not set; not inside tmux")
  path = value.split(",", 2).first
  raise NotInsideTmux.new("TMUX does not contain a socket path") if path.empty?
  new(nil, path, binary)
end

include Private
include Public
