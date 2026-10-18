require "./tmux.icr/*"

VERSION = "0.1.0"

case ARGV.size
when 1
  case ARGV[0]
  when "-v", "version", "--version"
    puts VERSION
    exit
  when "-h", "help", "--help"
    print_help
    exit
  end
end

require "time"
require "../tmux_repl"

name_parts = [] of String
if ENV["TMUX"]?
  caller_session = Tmux::Session.from_env.session_name
  name_parts << caller_session.gsub(/[^a-zA-Z0-9_-]/, "_")
end

now = Time.local
timestamp = now.to_s("%Y%m%d-%H%M%S")
timestamp += "-#{now.nanosecond.to_s.rjust(9, '0')}"

name_parts << "ic"
name_parts << timestamp

TmuxREPL::Session.crystal_interpreter(name_parts.join("-")).start
