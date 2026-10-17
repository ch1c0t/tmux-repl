getter server : Server
getter session_id : String
getter window_id : String
getter pane_id : String

def initialize(@server : Server, @session_id : String, @window_id : String, @pane_id : String)
end

def self.from_env(binary : String = "tmux") : Pane
  pane_id = ENV["TMUX_PANE"]? || raise NotInsideTmux.new("TMUX_PANE is not set; not inside a tmux pane")
  server = Server.from_env(binary)
  format = "\#{session_id}\t\#{window_id}"
  result = server.cmd("display-message", "-p", "-t", pane_id, format)
  raise CommandError.new(result) unless result.success?
  values = result.stdout.chomp.split('\t')
  raise Error.new("Could not resolve TMUX_PANE=#{pane_id}") unless values.size == 2
  new(server, values[0], values[1], pane_id)
end

include Private
include Public
