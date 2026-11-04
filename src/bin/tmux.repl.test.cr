require "./tmux.repl.test/*"

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

require "../tmux_repl"
require "../smoke_test"

begin
  SmokeTest.new.run
rescue ex
  STDERR.puts "tmux.repl smoke test: #{ex.class}: #{ex.message}"
  exit 1
end
