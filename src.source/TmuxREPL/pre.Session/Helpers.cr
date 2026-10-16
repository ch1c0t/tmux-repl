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
