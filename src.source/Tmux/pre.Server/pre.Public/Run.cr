def run!(*args : String) : CommandResult
  @client.run!(args)
end

def run!(args : Enumerable(String)) : CommandResult
  @client.run!(args)
end
