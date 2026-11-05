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
  started_at = Time.instant
  @stage = name
  yield
  elapsed = (Time.instant - started_at).total_milliseconds
  @report << {name: name, passed: true, duration_ms: elapsed, details: ""}
  sleep @step_delay if @step_delay.total_nanoseconds > 0
rescue ex
  elapsed = (Time.instant - started_at).total_milliseconds
  @report << {name: name, passed: false, duration_ms: elapsed, details: "#{ex.class}: #{ex.message}"}
  raise ex
end

private def return_to_origin : Nil
  started_at = Time.instant
  @origin_session.switch_client
  elapsed = (Time.instant - started_at).total_milliseconds
  @report << {
    name: "Return to original session",
    passed: true,
    duration_ms: elapsed,
    details: @origin_session_name,
  }
rescue ex
  elapsed = (Time.instant - started_at).total_milliseconds
  @report << {
    name: "Return to original session",
    passed: false,
    duration_ms: elapsed,
    details: "#{ex.class}: #{ex.message}",
  }
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

private def write_machine_report : String
  passed = @report.all? { |check| check[:passed] }
  finished_at = Time.utc.to_unix_ms
  directory = File.join(Dir.home, ".local", "state", "tmux-repl", "smoke-tests")
  FileUtils.mkdir_p(directory)

  path = File.join(directory, "smoke-test-#{@started_at.to_unix_ms}.json")
  temporary_path = "#{path}.tmp"

  contents = JSON.build(indent: "  ") do |json|
    json.object do
      json.field "schema_version", 1
      json.field "test", "tmux.repl"
      json.field "status", passed ? "passed" : "failed"
      json.field "exit_code", passed ? 0 : 1
      json.field "started_at_unix_ms", @started_at.to_unix_ms
      json.field "finished_at_unix_ms", finished_at
      json.field "original_session", @origin_session_name
      json.field "smoke_test_session", @repl_session_name
      json.field "checks" do
        json.array do
          @report.each do |check|
            json.object do
              json.field "name", check[:name]
              json.field "status", check[:passed] ? "passed" : "failed"
              json.field "duration_ms", check[:duration_ms]
              json.field "details", check[:details]
            end
          end
        end
      end
    end
  end

  File.write(temporary_path, contents + "\n")
  File.rename(temporary_path, path)
  path
end

private def print_report(machine_report_path : String) : Nil
  puts
  puts "tmux.repl smoke test"
  puts "=" * 72
  puts "Original session: #{@origin_session_name}"
  puts "Smoke-test session: #{repl_session_name}"
  puts

  @report.each do |check|
    marker = check[:passed] ? "\e[32mPASS\e[0m" : "\e[31mFAIL\e[0m"
    duration = "#{check[:duration_ms].round(0)} ms"
    details = check[:details]
    summary = details.empty? ? duration : "#{duration}; #{details}"
    puts "#{marker}  #{check[:name]} (#{summary})"
  end

  puts
  if session = @repl_session_name
    puts "The smoke-test session was left open: #{session}"
    puts "Return to it with: tmux switch-client -t '#{session}'"
  else
    puts "No smoke-test session was created."
  end
  puts "Machine-readable report: #{machine_report_path}"
end
