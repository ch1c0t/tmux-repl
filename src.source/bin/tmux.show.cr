require "../tmux_repl"

unless session_name = ARGV[0]?
  STDERR.puts "Usage: tmux.show SESSION"
  exit 2
end

events = TmuxREPL.stream_queue(Global.amqp_channel, TmuxREPL.events_queue_name(session_name))
events.subscribe(no_ack: true, block: true, args: {"x-stream-offset": "first"}) do |message|
  begin
    data = JSON.parse(message.body_io.to_s)
    case data["type"]?.try(&.as_s?)
    when "input"
      puts "\n$ #{data["command"].as_s}"
    when "output"
      print data["chunk"].as_s
      STDOUT.flush
    when "complete"
      puts unless data["command"]?.try(&.as_s?).try(&.ends_with?("\n"))
      puts "[exit status: #{data["status"].as_i64}]"
      STDOUT.flush
    end
  rescue ex
    STDERR.puts "tmux.show: invalid event: #{ex.message}"
  end
end
