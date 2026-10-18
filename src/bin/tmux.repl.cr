require "./tmux.repl/*"

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

def generate_session_name : String
  name_parts = [] of String

  if ENV["TMUX"]?
    caller_session = Tmux::Session.from_env.session_name
    name_parts << caller_session << "|" << "repl"
  else
    name_parts << "repl"
  end

  name_parts << "-" << timestamp

  name_parts.join
end

def timestamp
  now = Time.local
  string = now.to_s("%Y%m%d-%H%M%S")
  string += "-#{now.nanosecond.to_s.rjust(9, '0')}"
  string
end

require "../tmux_repl"

case ARGV[0]?
when "start"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).start
when "stop"
  TmuxREPL::Session.new(ARGV[1]? || ENV["TMUX_REPL_SESSION"]? || generate_session_name).stop
when "--repl"
  unless path = ARGV[1]?
    STDERR.puts "Missing output log path."
    exit 2
  end
  TmuxREPL.run_repl(path, ARGV[2]?)
else
  STDERR.puts "Unknown command or arguments."
  print_help
  exit 2
end
