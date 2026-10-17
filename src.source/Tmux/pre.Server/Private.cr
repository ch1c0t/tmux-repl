private def no_sessions_result?(result : CommandResult) : Bool
  return false if result.success?
  message = "#{result.stderr} #{result.stdout}".downcase
  message.includes?("no server running") || message.includes?("no sessions")
end

private def session_ids : Array(String)
  result = @client.run("list-sessions", "-F", "\#{session_id}")
  return [] of String if no_sessions_result?(result)
  raise CommandError.new(result) unless result.success?
  result.stdout_lines.reject(&.empty?)
end
