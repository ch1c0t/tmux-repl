class SmokeTest
  module Private
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
    
    private def expect_output_zoomed(expected : Bool) : Nil
      found = wait_until do
        zoomed = output_pane.display_message("\#{window_zoomed_flag}") == "1"
        zoomed == expected && (!expected || output_pane.active?)
      end
      return if found
    
      actual = output_pane.display_message("\#{window_zoomed_flag}") == "1"
      raise "Expected Output pane zoomed=#{expected}, got #{actual}."
    end
    
    private def restore_output_zoom : Nil
      pane = @output_pane
      return unless pane
      return unless pane.display_message("\#{window_zoomed_flag}") == "1"
    
      pane.select
      pane.run!("resize-pane", "-Z", "-t", pane.pane_id)
    rescue ex
      STDERR.puts "tmux.repl.test: failed to restore Output zoom: #{ex.message}"
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
      begin
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
    end
    
    private def return_to_origin : Nil
      started_at = Time.instant
      begin
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
      home = ENV["HOME"]? || raise "HOME is not set."
      directory = File.join(home, ".local", "state", "tmux-repl", "smoke-tests")
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
  end

  module Run
    def run : Nil
      begin
        step("Run ./bin/tmux.repl start") { start_repl }
        step("Find the new session and its two panes") { attach_panes }
        step("Submit the first command") do
          submit_command(1, "printf 'SMOKE_FIRST_OUTPUT\\n'", "SMOKE_FIRST_OUTPUT")
        end
        step("Submit the second command") do
          submit_command(2, "printf 'SMOKE_SECOND_OUTPUT\\n'", "SMOKE_SECOND_OUTPUT")
        end
        step("Ctrl+Up selects the previous output") do
          input_pane.send_keys("C-Up", enter: false)
          expect_output("INPUT #1", "SMOKE_FIRST_OUTPUT")
        end
        step("Ctrl+Down selects the next output") do
          input_pane.send_keys("C-Down", enter: false)
          expect_output("INPUT #2", "SMOKE_SECOND_OUTPUT")
        end
        step("Alt+K selects the previous output") do
          input_pane.send_keys("M-k", enter: false)
          expect_output("INPUT #1", "SMOKE_FIRST_OUTPUT")
        end
        step("Alt+J selects the next output") do
          input_pane.send_keys("M-j", enter: false)
          expect_output("INPUT #2", "SMOKE_SECOND_OUTPUT")
        end
        step("Ctrl+L opens the available-outputs list from the input pane") do
          input_pane.send_keys("C-l", enter: false)
          expect_output("AVAILABLE OUTPUTS (2)", "#1", "#2")
        end
        step("Ctrl+L closes the list from the output pane") do
          output_pane.send_keys("C-l", enter: false)
          expect_output("INPUT #2", "SMOKE_SECOND_OUTPUT")
        end
        step("Submit a command for raw/stripped view testing") do
          command = %(for i in $(seq 1 4); do printf 'SMOKE_STREAM_TICK_%s\\n' "$i" && sleep 0.15; done)
          submit_command(3, command, "SMOKE_STREAM_TICK_4")
        end
        step("Ctrl+G from the input pane switches to raw output") do
          input_pane.send_keys("C-g", enter: false)
          expect_output("[RAW;", "START_MARK_", "END_MARK_")
        end
        step("Ctrl+G from the output pane switches back to stripped output") do
          output_pane.send_keys("C-g", enter: false)
          expect_output("[STRIPPED;", "SMOKE_STREAM_TICK_4")
          expect_output_without("START_MARK_")
          expect_output_without("END_MARK_")
        end
        step("Submit a command with enough lines to scroll") do
          command = %(for i in $(seq 1 60); do printf 'SMOKE_SCROLL_LINE_%02d\\n' "$i"; done)
          submit_command(4, command, "SMOKE_SCROLL_LINE_60")
        end
        step("PageUp in the output pane reaches the first lines") do
          4.times { output_pane.send_keys("PageUp", enter: false) }
          expect_output("SMOKE_SCROLL_LINE_01")
          expect_output_without("SMOKE_SCROLL_LINE_60")
        end
        step("Down in the output pane scrolls by one line") do
          output_pane.send_keys("Down", enter: false)
          expect_output("SMOKE_SCROLL_LINE_02")
        end
        step("Up in the output pane scrolls back by one line") do
          output_pane.send_keys("Up", enter: false)
          expect_output("SMOKE_SCROLL_LINE_01")
        end
        step("PageDown in the output pane returns to the latest lines") do
          4.times { output_pane.send_keys("PageDown", enter: false) }
          expect_output("SMOKE_SCROLL_LINE_60")
        end
        step("Alt+PageUp in the input pane reaches the first lines") do
          4.times { input_pane.send_keys("M-PageUp", enter: false) }
          expect_output("SMOKE_SCROLL_LINE_01")
          expect_output_without("SMOKE_SCROLL_LINE_60")
        end
        step("Alt+Down in the input pane scrolls by one line") do
          input_pane.send_keys("M-Down", enter: false)
          expect_output("SMOKE_SCROLL_LINE_02")
        end
        step("Alt+Up in the input pane scrolls back by one line") do
          input_pane.send_keys("M-Up", enter: false)
          expect_output("SMOKE_SCROLL_LINE_01")
        end
        step("Alt+PageDown in the input pane returns to the latest lines") do
          4.times { input_pane.send_keys("M-PageDown", enter: false) }
          expect_output("SMOKE_SCROLL_LINE_60")
        end
        step("Alt+Z from Input zooms Output") do
          input_pane.send_keys("M-z", enter: false)
          expect_output_zoomed(true)
        end
        step("Alt+Z from Output restores the split") do
          output_pane.send_keys("M-z", enter: false)
          expect_output_zoomed(false)
        end
        step("Alt+Z from Output zooms Output") do
          output_pane.send_keys("M-z", enter: false)
          expect_output_zoomed(true)
        end
        step("Alt+Z from Input restores the split") do
          input_pane.send_keys("M-z", enter: false)
          expect_output_zoomed(false)
        end
        step("Leave the smoke-test session running") do
          unless @server.cmd("has-session", "-t", repl_session_name).success?
            raise "The smoke-test Tmux session disappeared."
          end
        end
      rescue ex
        last = @report.last?
        unless last && !last[:passed]
          @report << {
            name: "Smoke test",
            passed: false,
            duration_ms: 0.0,
            details: "#{@stage}: #{ex.class}: #{ex.message}",
          }
        end
      ensure
        restore_output_zoom
        return_to_origin
      end
    
      report_path = write_machine_report
      print_report(report_path)
      exit 1 unless @report.all? { |check| check[:passed] }
    end
  end

  TIMEOUT = 8.seconds
  
  @server : Tmux::Server
  @origin_session : Tmux::Session
  @origin_session_name : String
  @repl_session : Tmux::Session?
  @repl_session_name : String?
  @input_pane : Tmux::Pane?
  @output_pane : Tmux::Pane?
  @step_delay : Time::Span
  @started_at : Time
  @stage = "initialize"
  @report = [] of NamedTuple(
    name: String,
    passed: Bool,
    duration_ms: Float64,
    details: String
  )
  
  def initialize
    unless ENV["TMUX"]? && ENV["TMUX_PANE"]?
      raise "Run ./bin/tmux.repl.test from inside the tmux session you want to return to."
    end
  
    @server = Tmux::Server.from_env
    @origin_session = Tmux::Session.from_env
    @origin_session_name = @origin_session.session_name
    @started_at = Time.utc
  
    delay = ENV["TMUX_REPL_TEST_DELAY"]?.try(&.to_f?) || 0.8
    delay = 0.0 if delay < 0
    @step_delay = delay.seconds
  end
  
  include Private
  include Run
end