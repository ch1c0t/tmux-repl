# Overload for a pre-built array/collection
def run(args : Enumerable(String)) : CommandResult
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  # args is already a collection, so we can convert it straight to an array
  status = Process.run(@binary, @server_options + args.to_a, output: stdout, error: stderr)
  CommandResult.new(args.to_a, stdout.to_s, stderr.to_s, status.exit_code)
rescue ex
  raise Error.new("Unable to execute #{@binary}: #{ex.message || ex.class.name}")
end

# Keep this for backward compatibility (e.g., run("status", "-v"))
def run(*args : String) : CommandResult
  run(args)
end

# Overload for a pre-built array/collection
def run!(args : Enumerable(String)) : CommandResult
  result = run(args)
  raise CommandError.new(result) unless result.success?
  result
end

# Keep this for backward compatibility (e.g., run!("status"))
def run!(*args : String) : CommandResult
  run!(args)
end
