private def start_repl : Nil
  existing_session_ids = @server.sessions.map(&.session_id)
  unless File::Info.executable?("./bin/tmux.repl")
    raise "Missing ./bin/tmux.repl. Build the executables first with shards build."
  end

  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(
    "./bin/tmux.repl",
    ["start"],
    env: {"TMUX_REPL_SESSION" => nil},
    output: stdout,
    error: stderr
  )
  unless status.success?
    raise "./bin/tmux.repl start failed (#{status.exit_code}).\n#{stdout}\n#{stderr}"
  end

  created : Tmux::Session? = nil
  found = wait_until do
    created = @server.sessions.find do |session|
      !existing_session_ids.includes?(session.session_id) &&
        session.session_name.starts_with?("#{@origin_session_name}|repl-")
    end
    !created.nil?
  end
  raise "Could not find the session created by ./bin/tmux.repl start." unless found

  @repl_session = created
  @repl_session_name = created.not_nil!.session_name
end

private def attach_panes : Nil
  session = @repl_session || raise "The REPL session was not created."
  panes = session.active_window.panes
  raise "Expected two panes, found #{panes.size}." unless panes.size == 2

  @input_pane = panes[0]
  @output_pane = panes[1]
  expect_output("No inputs yet.", timeout: 3.seconds)
end

private def submit_command(sequence : Int32, command : String, expected_output : String) : Nil
  input_pane.send_keys(command, literal: true)
  expect_output("INPUT ##{sequence}", expected_output, "[exit status: 0]")
end

private def expect_output(*expected : String, timeout : Time::Span = TIMEOUT) : Nil
  last_text = ""
  expected = expected.to_a
  found = wait_until(timeout) do
    last_text = pane_text(output_pane)
    expected.all? { |text| last_text.includes?(text) }
  end
  return if found

  missing = expected.reject { |text| last_text.includes?(text) }
  raise "Timed out waiting for output pane to show #{missing.map(&.inspect).join(", ")}.\n#{last_text}"
end

private def expect_output_without(marker : String) : Nil
  text = pane_text(output_pane)
  raise "Output pane still contains #{marker.inspect}.\n#{text}" if text.includes?(marker)
end

private def pane_text(pane : Tmux::Pane) : String
  pane.capture_pane(join_wrapped: true).join("\n")
end

private def wait_until(
  timeout : Time::Span = TIMEOUT,
  interval : Time::Span = 25.milliseconds,
  &condition : -> Bool
) : Bool
  deadline = Time.instant + timeout

  while Time.instant < deadline
    return true if yield
    sleep interval
  end

  yield
end

private def step(name : String, &block : -> Nil) : Nil
  @stage = name
  started_at = Time.instant
  yield
  elapsed = (Time.instant - started_at).total_milliseconds.round(0)
  @report << {name, true, "#{elapsed} ms"}
  sleep @step_delay if @step_delay.total_nanoseconds > 0
rescue ex
  @report << {name, false, "#{ex.class}: #{ex.message}"}
  raise ex
end

private def return_to_origin : Nil
  @origin_session.switch_client
  @report << {"Return to original session", true, @origin_session_name}
rescue ex
  @report << {"Return to original session", false, "#{ex.class}: #{ex.message}"}
end

private def repl_session_name : String
  @repl_session_name || "(not created)"
end

private def input_pane : Tmux::Pane
  @input_pane || raise "Input pane is not available."
end

private def output_pane : Tmux::Pane
  @output_pane || raise "Output pane is not available."
end

private def print_report : Nil
  puts
  puts "tmux.repl smoke test"
  puts "=" * 72
  puts "Original session: #{@origin_session_name}"
  puts "Smoke-test session: #{repl_session_name}"
  puts

  @report.each do |name, passed, details|
    marker = passed ? "\e[32mPASS\e[0m" : "\e[31mFAIL\e[0m"
    puts "#{marker}  #{name} (#{details})"
  end

  puts
  if session = @repl_session_name
    puts "The smoke-test session was left open: #{session}"
    puts "Return to it with: tmux switch-client -t '#{session}'"
  else
    puts "No smoke-test session was created."
  end
  puts "The report is displayed in the original session."
end
