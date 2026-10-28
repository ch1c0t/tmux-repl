private def amqp_environment : Hash(String, String)
  socket_path = ENV["LAVINMQ_AMQP_UNIXSOCKET"]?
  raise "Missing critical environment configuration variable: LAVINMQ_AMQP_UNIXSOCKET" unless socket_path

  {"LAVINMQ_AMQP_UNIXSOCKET" => socket_path}
end

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
  program_path = File.expand_path(PROGRAM_NAME)
  sibling = File.join(File.dirname(program_path), name)
  return sibling if File::Info.executable?(sibling)

  if search_path = ENV["PATH"]?
    search_path.split(':').each do |directory|
      directory = "." if directory.empty?
      candidate = File.expand_path(name, directory)
      return candidate if File::Info.executable?(candidate)
    end
  end

  raise "Cannot find executable #{name.inspect} beside #{program_path.inspect} or on PATH"
end

private def shell_quote(value : String) : String
  "'#{value.gsub("'", "'\\''")}'"
end
