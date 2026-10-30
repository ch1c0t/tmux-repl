require "reply"
require "../tmux_repl"


class TmuxREPLInputReader < Reply::Reader
  @ready_path : String

  def initialize(@ready_path : String)
    super()
  end

  def prompt(io : IO, line_number : Int32, color : Bool)
    super(io, line_number, color)
    File.write(@ready_path, Process.pid.to_s) unless File.exists?(@ready_path)
  end
end

unless ARGV[0]? == "--input"
  STDERR.puts "Usage: tmux.repl.input --input SESSION"
  exit 2
end

unless session_name = ARGV[1]?
  STDERR.puts "Missing session name."
  exit 2
end

TmuxREPL::InputProcess.new(session_name).run do |ready_path|
  TmuxREPLInputReader.new(ready_path)
end
