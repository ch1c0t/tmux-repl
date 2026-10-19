record Result, command : String, output : String, status : Int32

def self.execute(command : String) : Result
  execute(command) { |_chunk| }
end

def self.execute(command : String, &stream_callback : String -> Nil) : Result
  output, status = PTY.run(["/bin/sh", "-c", command], &stream_callback)
  Result.new(command, output, status)
end

def self.write_result(path : String, result : Result) : Nil
  begin_result(path, result.command)
  append_output(path, result.output)
  finish_result(path, result)
end

def self.begin_result(path : String, command : String) : Nil
  File.open(path, "a") { |io| io.puts "$ #{command}" }
end

def self.append_output(path : String, output : String) : Nil
  return if output.empty?
  File.open(path, "a") { |io| io.print output }
end

def self.finish_result(path : String, result : Result) : Nil
  File.open(path, "a") do |io|
    io.puts unless result.output.empty? || result.output.ends_with?("\n")
    io.puts "[exit status: #{result.status}]"
    io.puts
  end
end

def self.run_repl(path : String, session_name : String? = nil) : Nil
  name = session_name || File.basename(File.dirname(path))
  stream = CommandStream.new(name)
  reader = Reply::Reader.new
  reader.read_loop do |expression|
    next if expression.strip.empty?
    stream.publish(expression)
    begin_result(path, expression)
    result = execute(expression) { |chunk| append_output(path, chunk) }
    finish_result(path, result)
  end
end

def self.show(path : String) : Nil
  Process.exec("tail", ["-n", "+1", "-f", path])
end
