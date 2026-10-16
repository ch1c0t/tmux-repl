record Result, command : String, stdout : String, stderr : String, status : Int32

def self.execute(command : String) : Result
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run("/bin/sh", ["-lc", command], output: stdout, error: stderr)
  Result.new(command, stdout.to_s, stderr.to_s, status.exit_code)
rescue ex
  Result.new(command, "", ex.message || ex.class.name, 1)
end

def self.write_result(path : String, result : Result) : Nil
  File.open(path, "w") do |io|
    io.puts "$ #{result.command}"
    io.print result.stdout unless result.stdout.empty?
    io.print result.stderr unless result.stderr.empty?
    last = result.stderr.empty? ? result.stdout : result.stderr
    io.puts unless last.empty? || last.ends_with?("\n")
    io.puts "[exit status: #{result.status}]"
  end
end

def self.run_repl(path : String) : Nil
  reader = Reply::Reader.new
  reader.read_loop do |expression|
    next if expression.strip.empty?
    write_result(path, execute(expression))
  end
end
