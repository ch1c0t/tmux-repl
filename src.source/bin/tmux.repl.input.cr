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

base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
state_dir = File.join(base, "tmux-repl", session_name)
input_pid_path = File.join(state_dir, "input.pid")
startup_error_path = File.join(state_dir, "input.error")
File.delete(startup_error_path) if File.exists?(startup_error_path)

begin
  channel = Global.amqp_channel
commands = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(session_name))
events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(session_name))
reader = TmuxREPLInputReader.new(input_pid_path)
sequence = 0_u64
selected_sequence : UInt64? = nil
history = [] of Tuple(UInt64, String)

  reader.read_loop do |expression|
    next if expression.strip.empty?
    control = expression.strip

    if match = control.match(/\A:select\s+([0-9]+)\z/)
      target = match[1].to_u64
      if history.any? { |entry| entry[0] == target }
        TmuxREPL.publish_event(events, "select", session_name, target)
        selected_sequence = target
        puts "Selected input ##{target}."
      else
        puts "No input ##{target}. Use :list to see submitted inputs."
      end
      next
    end

    case control
    when ":prev"
      if current = selected_sequence
        index = history.index { |entry| entry[0] == current }
        if index && index > 0
          target = history[index - 1][0]
          TmuxREPL.publish_event(events, "select", session_name, target)
          selected_sequence = target
          puts "Selected input ##{target}."
        else
          puts "Already at the oldest input."
        end
      else
        puts "No inputs have been submitted."
      end
      next
    when ":next"
      if current = selected_sequence
        index = history.index { |entry| entry[0] == current }
        if index && index < history.size - 1
          target = history[index + 1][0]
          TmuxREPL.publish_event(events, "select", session_name, target)
          selected_sequence = target
          puts "Selected input ##{target}."
        else
          puts "Already at the newest input."
        end
      else
        puts "No inputs have been submitted."
      end
      next
    when ":list"
      if history.empty?
        puts "No inputs have been submitted."
      else
        history.each do |entry|
          marker = entry[0] == selected_sequence ? "*" : " "
          puts "#{marker} ##{entry[0]}: #{entry[1].lines.first? || entry[1]}"
        end
      end
      next
    when ":help"
      puts ":select ID  Show the output for a previously submitted input."
      puts ":prev       Select the previous input."
      puts ":next       Select the next input."
      puts ":list       List submitted inputs."
      next
    end

    sequence &+= 1_u64
    history << {sequence, expression}
    selected_sequence = sequence
    TmuxREPL.publish_event(events, "input", session_name, sequence, command: expression)
    TmuxREPL.publish_command(commands, session_name, sequence, expression)
    puts "[input ##{sequence}] submitted. Use :select ID, :prev, :next, :list, or :help."
  end
rescue ex
  File.write(startup_error_path, "#{ex.class}: #{ex.message}")
  STDERR.puts "tmux.repl.input: #{ex.class}: #{ex.message}"
  exit 1
ensure
  File.delete(input_pid_path) if File.exists?(input_pid_path)
end
