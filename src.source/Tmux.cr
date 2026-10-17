class Error < Exception
end

class CommandError < Error
  getter result : CommandResult

  def initialize(@result : CommandResult)
    detail = @result.stderr.strip
    detail = "exit status #{@result.exit_code}" if detail.empty?
    super("tmux command failed (#{@result.exit_code}): #{detail}")
  end
end

class NotInsideTmux < Error
end
