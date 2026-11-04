require "../tmux_repl"
require "../smoke_test"

begin
  SmokeTest.new.run
rescue ex
  STDERR.puts "tmux.repl smoke test: #{ex.class}: #{ex.message}"
  exit 1
end
