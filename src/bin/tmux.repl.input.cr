require "./tmux.repl.input/*"

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

require "../input"

unless ARGV[0]? == "--input"
  STDERR.puts "Usage: tmux.repl.input --input SESSION"
  exit 2
end

unless session_name = ARGV[1]?
  STDERR.puts "Missing session name."
  exit 2
end

Input::Runner.new(session_name).run
