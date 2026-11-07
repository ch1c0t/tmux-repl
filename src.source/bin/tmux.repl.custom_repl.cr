require "../tmux_repl"

class CustomREPLFixtureBackend
  def latest_ocr : String
    "SCREEN OCR: fixture display is ready"
  end

  def send_key(action : String, key : String) : String
    "KEY EVENT: #{action} #{key}"
  end
end

backend = CustomREPLFixtureBackend.new
session_name = ENV["TMUX_REPL_SESSION"]? || "tmux-repl-custom-fixture"

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

begin
  # Interactive use should enter the new Tmux session. The end-to-end test
  # explicitly opts out so it can inspect the panes from its controlling client.
  focus = ENV["TMUX_REPL_CUSTOM_REPL_FOCUS"]? != "0"
  definition.start(focus: focus)
  definition.serve
rescue ex
  STDERR.puts "tmux.repl.custom_repl: #{ex.class}: #{ex.message}"
  exit 1
end
