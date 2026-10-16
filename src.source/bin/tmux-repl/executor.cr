module TmuxRepl
  record Result, command : String, stdout : String, stderr : String, status : Int32

  def self.execute(command : String) : Result
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run("/bin/sh", ["-lc", command], output: stdout, error: stderr)
    Result.new(command, stdout.to_s, stderr.to_s, status.exit_code)
  rescue ex
    Result.new(command, "", ex.message || ex.class.name, 1)
  end
end