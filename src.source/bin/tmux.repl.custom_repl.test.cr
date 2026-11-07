require "../tmux_repl"

begin
  CustomREPL::SmokeTest.new.run
rescue ex
  STDERR.puts "tmux.repl.custom_repl.test: #{ex.class}: #{ex.message}"
  exit 1
end
