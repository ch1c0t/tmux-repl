private def state_dir : String
  base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
  File.join(base, "tmux-repl", @name)
end

private def repl_executable : String
  path = File.expand_path(PROGRAM_NAME)
  return path if File.basename(path) == "tmux.repl" && File::Info.executable?(path)
  "tmux.repl"
end

private def worker_executable : String
  path = File.expand_path(PROGRAM_NAME)
  sibling = File.join(File.dirname(path), "tmux.repl.input")
  File::Info.executable?(sibling) ? sibling : "tmux.repl.input"
end

private def show_executable : String
  path = File.expand_path(PROGRAM_NAME)
  sibling = File.join(File.dirname(path), "tmux.show")
  File::Info.executable?(sibling) ? sibling : "tmux.show"
end

private def shell_quote(value : String) : String
  "'#{value.gsub("'", "'\\''")}'"
end
