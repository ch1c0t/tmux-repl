private def write_machine_report : String
  passed = @report.all? { |check| check[:passed] }
  finished_at = Time.utc.to_unix_ms
  directory = State.smoke_tests_path
  FileUtils.mkdir_p(directory)

  path = File.join(directory, "smoke-test-#{@started_at.to_unix_ms}-#{Process.pid}.json")
  temporary_path = "#{path}.tmp"

  contents = JSON.build(indent: "  ") do |json|
    json.object do
      json.field "schema_version", 1
      json.field "test", @name
      json.field "status", passed ? "passed" : "failed"
      json.field "exit_code", passed ? 0 : 1
      json.field "started_at_unix_ms", @started_at.to_unix_ms
      json.field "finished_at_unix_ms", finished_at
      json.field "original_session", @origin_session_name
      json.field "smoke_test_session", @session_name
      json.field "custom_host_pid", @host_process.try(&.pid)
      json.field "custom_host_log", @host_log_path
      json.field "session_cleaned", @session_cleaned
      json.field "configuration" do
        json.object do
          json.field "focus", @focus
          json.field "cleanup", @cleanup.to_s
          json.field "restore_client", @restore_client
          json.field "step_delay_seconds", @step_delay.total_seconds
          json.field "timeout_seconds", @timeout.total_seconds
          json.field "start_timeout_seconds", @start_timeout.total_seconds
          json.field "host_stop_timeout_seconds", @host_stop_timeout.total_seconds
        end
      end
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
  puts "#{@name} smoke test"
  puts "=" * 72
  puts "Original session: #{@origin_session_name}"
  puts "Smoke-test session: #{@session_name || "(not created)"}"
  puts

  @report.each do |check|
    marker = check[:passed] ? "\e[32mPASS\e[0m" : "\e[31mFAIL\e[0m"
    duration = "#{check[:duration_ms].round(0)} ms"
    details = check[:details]
    summary = details.empty? ? duration : "#{duration}; #{details}"
    puts "#{marker}  #{check[:name]} (#{summary})"
  end

  puts
  if name = @session_name
    if @session_cleaned
      puts "The temporary smoke-test session was cleaned up: #{name}"
    else
      puts "The smoke-test session was left open: #{name}"
      puts "Return to it with: tmux switch-client -t '#{name}'"
    end
  else
    puts "No smoke-test session was created."
  end
  puts "Machine-readable report: #{machine_report_path}"
end
