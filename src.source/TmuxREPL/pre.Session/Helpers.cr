private def state_dir : String
  base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
  File.join(base, "tmux-repl", @name)
end

private def repl_executable : String
  sibling_executable("tmux.repl")
end

private def input_executable : String
  sibling_executable("tmux.repl.input")
end

private def output_executable : String
  sibling_executable("tmux.repl.output")
end

private def worker_executable : String
  sibling_executable("tmux.repl.worker")
end

private def sibling_executable(name : String) : String
  path = File.expand_path(PROGRAM_NAME)
  sibling = File.join(File.dirname(path), name)
  File::Info.executable?(sibling) ? sibling : name
end

private def shell_quote(value : String) : String
  "'#{value.gsub("'", "'\\''")}'"
end
