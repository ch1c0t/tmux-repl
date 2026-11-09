require "./tmux.repl.custom_repl/*"

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

class FixtureBackend
  def latest_ocr : String
    "SCREEN OCR: fixture display is ready"
  end

  def send_key(action : String, key : String) : String
    "KEY EVENT: #{action} #{key}"
  end
end

def start_custom_repl(session_name : String, focus : Bool) : Nil
  backend = FixtureBackend.new

  definition = TmuxREPL.define(session_name) do |repl|
    repl.on_command("ocr") do |context, arguments|
      raise ArgumentError.new("Usage: ocr") unless arguments.empty?
      context.puts(backend.latest_ocr)
    end

    repl.on_command("key") do |context, arguments|
      unless arguments.size == 2 && {"press", "release"}.includes?(arguments[0])
        raise ArgumentError.new("Usage: key press|release KEY")
      end

      context.puts(backend.send_key(arguments[0], arguments[1]))
    end

    repl.on_command("echo") do |context, arguments|
      context.puts(arguments.join(" "))
    end

    repl.on_command("fail") do |_context, _arguments|
      raise "fixture failure"
    end
  end

  definition.start(focus: focus)
  definition.serve
end

case ARGV[0]?
when "start"
  arguments = ARGV[1..]
  no_focus = !arguments.delete("--no-focus").nil?

  if arguments.size != 1
    STDERR.puts "Usage: tmux.repl.custom_repl start SESSION [--no-focus]"
    exit 2
  end

  begin
    start_custom_repl(arguments.first, !no_focus)
  rescue ex
    STDERR.puts "tmux.repl.custom_repl: #{ex.class}: #{ex.message}"
    exit 1
  end
when "--help", "help"
  puts "Usage: tmux.repl.custom_repl start SESSION [--no-focus]"
else
  STDERR.puts "Unknown command or arguments."
  STDERR.puts "Usage: tmux.repl.custom_repl start SESSION [--no-focus]"
  exit 2
end
