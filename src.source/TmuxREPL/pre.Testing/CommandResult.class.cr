getter sequence : Int32
getter command : String
getter status : Int32?

@output = ""
@completed = false

def initialize(
  @runner : Testing,
  @sequence : Int32,
  @command : String
)
  @status = nil
end

# Wait for protocol output first, then verify that the Output pane rendered it.
def expect_output(
  *expected : String,
  timeout : Time::Span? = nil
) : self
  expected_items = expected.to_a
  timeout = timeout || @runner.timeout
  deadline = Time.instant + timeout

  until expected_items.all? { |item| output.includes?(item) } || @completed
    remaining = deadline - Time.instant
    raise "Timed out waiting for command ##{@sequence} output; received: #{output.inspect}" if remaining <= Time::Span.zero
    @runner.receive_command_event(self, remaining)
  end

  missing = expected_items.reject { |item| output.includes?(item) }
  raise "Command ##{@sequence} completed without expected output #{missing.map(&.inspect).join(", ")}; received: #{output.inspect}" unless missing.empty?

  @runner.expect_command_output(@sequence, expected_items, timeout)
  self
end

def expect_status(
  status : Int32,
  timeout : Time::Span? = nil
) : self
  timeout = timeout || @runner.timeout
  wait_for_completion(timeout)
  raise "Command ##{@sequence} exited with status #{@status.inspect}, expected #{status}." unless @status == status

  @runner.expect_command_status(@sequence, status, timeout)
  self
end

def expect_complete(
  timeout : Time::Span? = nil
) : self
  timeout = timeout || @runner.timeout
  wait_for_completion(timeout)
  @runner.expect_command_complete(@sequence, timeout)
  self
end

def output : String
  @output
end

def accept(event : Event) : Nil
  if event.type == "output"
    @output += event.chunk.not_nil! if event.chunk
  elsif event.type == "complete"
    @status = event.status
    @completed = true
    if @output.empty? && (clean = event.clean_output)
      @output = clean
    end
  end
end

private def wait_for_completion(timeout : Time::Span) : Nil
  deadline = Time.instant + timeout
  until @completed
    remaining = deadline - Time.instant
    raise "Timed out waiting for command ##{@sequence} completion." if remaining <= Time::Span.zero
    @runner.receive_command_event(self, remaining)
  end
end
