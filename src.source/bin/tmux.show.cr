require "../tmux_repl"

if ARGV[0]? == "--log"
  unless path = ARGV[1]?
    STDERR.puts "Usage: tmux.show --log LOG"
    exit 2
  end
  Process.exec("tail", ["-n", "+1", "-f", path])
end

unless session_name = ARGV[0]?
  STDERR.puts "Usage: tmux.show SESSION"
  exit 2
end

channel = Global.amqp_channel
channel.prefetch(10)
events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(session_name))
events.subscribe(no_ack: false, block: true, args: {"x-stream-offset": "first"}) do |message|
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
  ensure
    message.ack
  end
end
