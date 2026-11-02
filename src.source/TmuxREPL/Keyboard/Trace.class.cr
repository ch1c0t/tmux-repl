@file : File? = nil
@previous_monotonic_at : Time::Instant?

def initialize(session_name : String, pane : String, path : String? = nil)
  @pane = pane
  return unless path || trace_enabled?

  begin
    trace_path = path || self.class.path_for(session_name)
    FileUtils.mkdir_p(File.dirname(trace_path))
    @file = File.open(trace_path, "a")
    File.chmod(trace_path, 0o600)
  rescue ex
    @file.try &.close
    @file = nil
    STDERR.puts "tmux.repl.#{@pane}: cannot open keyboard trace: #{ex.message}"
  end
end

def self.path_for(session_name : String) : String
  base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
  session = ENV["TMUX_REPL_SESSION_NAME"]? || session_name
  File.join(base, "tmux-repl", session, "keyboard.trace.log")
end

def record(press : KeyPress, action : String, result : String) : Nil
  return unless file = @file

  elapsed = if previous = @previous_monotonic_at
    (press.monotonic_at - previous).total_milliseconds.round(3).to_s
  else
    "first"
  end

  line = String.build do |io|
    io << "pressed_at=" << press.pressed_at.to_rfc3339(fraction_digits: 6)
    io << " pane=" << @pane
    io << " pid=" << Process.pid
    if key = press.key
    io << " key=" << key
  else
    io << " character=" << press.character.inspect
  end
    io << " action=" << action
    io << " elapsed_since_previous_ms=" << elapsed
    io << " result=" << result
    io << 10_u8.chr
  end

  file.flock_exclusive do
    file.write(line.to_slice)
    file.flush
  end
  @previous_monotonic_at = press.monotonic_at
rescue ex
  STDERR.puts "tmux.repl.#{@pane}: cannot write keyboard trace: #{ex.message}"
end

def close : Nil
  if file = @file
    file.close unless file.closed?
  end
rescue ex
  STDERR.puts "tmux.repl.#{@pane}: cannot close keyboard trace: #{ex.message}"
ensure
  @file = nil
end

private def trace_enabled? : Bool
  ENV["LOG_LEVEL"]?.try(&.upcase) == "TRACE"
end
