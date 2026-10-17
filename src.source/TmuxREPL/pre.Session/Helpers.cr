private def state_dir : String
  base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
  File.join(base, "tmux-repl", @name)
end

private def repl_executable : String
  path = File.expand_path(PROGRAM_NAME)
  File::Info.executable?(path) ? path : "tmux.repl"
end

private def show_executable : String
  path = File.expand_path(PROGRAM_NAME)
  sibling = File.join(File.dirname(path), "tmux.show")
  File::Info.executable?(sibling) ? sibling : "tmux.show"
end

private def tmux?(*args : String) : Bool
  Process.run("tmux", args.to_a, output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

private def shell_quote(value : String) : String
  "'#{value.gsub("'", "'\\''")}'"
end

private def ensure_input_pane_left : Nil
  input_pane = "#{@name}:0.0"
  output_pane = "#{@name}:0.1"
  if pane_left(input_pane) > pane_left(output_pane)
    raise "Could not move input pane to the left" unless tmux?("swap-pane", "-d", "-s", input_pane, "-t", output_pane)
  end
end

private def pane_left(pane : String) : Int32
  stdout = IO::Memory.new
  status = Process.run(
    "tmux",
    ["display-message", "-p", "-t", pane, "\#{pane_left}"],
    output: stdout,
    error: Process::Redirect::Close
  )
  raise "Could not determine tmux pane position" unless status.success?
  stdout.to_s.strip.to_i
end
