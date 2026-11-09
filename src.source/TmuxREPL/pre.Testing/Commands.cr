def submit(command : String) : CommandResult
  @sequence += 1
  input_pane.send_keys(command, literal: true)
  CommandResult.new(self, @sequence, command)
end

def press(pane : Symbol, key : String) : Nil
  target = case pane
           when :input
             input_pane
           when :output
             output_pane
           else
             raise ArgumentError.new("pane must be :input or :output, got #{pane.inspect}")
           end
  target.send_keys(key, enter: false)
end

def receive_command_event(result : CommandResult, timeout : Time::Span) : Nil
  events = @event_channel || raise "The REPL event consumer has not started."

  if host_exit = @host_exit
    select
    when event = events.receive
      result.accept(event) if event.sequence == result.sequence.to_i64
    when status = host_exit.receive
      @host_status = status
      raise_host_exit!(status)
    when timeout(timeout)
      raise "Timed out waiting for a protocol event for command ##{result.sequence}."
    end
  else
    select
    when event = events.receive
      result.accept(event) if event.sequence == result.sequence.to_i64
    when timeout(timeout)
      raise "Timed out waiting for a protocol event for command ##{result.sequence}."
    end
  end
end

def expect_command_output(
  sequence : Int32,
  expected : Array(String),
  timeout : Time::Span
) : Nil
  expect_visible_items(["INPUT ##{sequence}"] + expected, timeout)
end

def expect_command_status(
  sequence : Int32,
  status : Int32,
  timeout : Time::Span
) : Nil
  expect_visible("INPUT ##{sequence}", "[exit status: #{status}]", timeout: timeout)
end

def expect_command_complete(
  sequence : Int32,
  timeout : Time::Span
) : Nil
  last_text = ""
  found = wait_until(timeout) do
    last_text = current_output
    last_text.includes?("INPUT ##{sequence}") && last_text.includes?("[exit status:")
  end
  return if found

  raise "Timed out waiting for command ##{sequence} to complete.\n#{last_text}"
end
