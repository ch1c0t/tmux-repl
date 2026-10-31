module LavinMQProcess
  module Diagnostics
    private def diagnostic_details : String
      details = [
        "scenario: #{name}",
        "stage: #{@stage}",
        "state home: #{@state_home}",
        "worker pid file: #{file_state(@worker_pid_path)}",
        "ready pid files:",
      ]

      @ready_paths.each do |path|
        details << "  #{path}: #{file_state(path)}"
      end

      details << pane_snapshot("input", @input_pane)
      details << pane_snapshot("output", @output_pane)
      details << tmux_snapshot

      begin
        channel = Global.amqp_channel
        commands = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(name))
        events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(name))
        details << "command stream messages: #{commands.message_count}"
        details << "event stream messages: #{events.message_count}"
      rescue ex
        details << "queue diagnostics failed: #{ex.class}: #{ex.message}"
      end

      details.join("\n")
    end

    private def file_state(path : String) : String
      File.exists?(path) ? File.read(path).strip : "missing"
    rescue ex
      "unreadable (#{ex.class}: #{ex.message})"
    end

    private def pane_snapshot(label : String, pane : Tmux::Pane?) : String
      return "#{label} pane: not attached yet" unless pane

      "#{label} pane contents:\n#{pane_text(pane)}"
    rescue ex
      "#{label} pane capture failed: #{ex.class}: #{ex.message}"
    end

    private def tmux_snapshot : String
      result = @server.cmd("list-sessions")
      output = result.stdout.strip
      output = "(no session listing output)" if output.empty?
      "tmux list-sessions (success: #{result.success?}):\n#{output}"
    rescue ex
      "tmux session listing failed: #{ex.class}: #{ex.message}"
    end

    private def fail_with_diagnostics(message : String) : Nil
      raise "#{message}\n\n#{diagnostic_details}"
    end

    private def expect_condition(condition : Bool, description : String) : Nil
      return if condition

      fail_with_diagnostics(description)
    end

    private def expect_equal(expected : T, actual : T, description : String) : Nil forall T
      return if expected == actual

      fail_with_diagnostics(
        "#{description}\nExpected: #{expected.inspect}\nActual: #{actual.inspect}"
      )
    end

    private def expect_pane(
      pane : Tmux::Pane,
      label : String,
      expected : Array(String),
      timeout : Time::Span = 5.seconds
    ) : Nil
      last_text = ""
      capture_error : String? = nil

      matched = wait_until(timeout, 25.milliseconds) do
        begin
          last_text = pane_text(pane)
          expected.all? { |text| last_text.includes?(text) }
        rescue ex
          capture_error = "#{ex.class}: #{ex.message}"
          false
        end
      end
      return if matched

      missing = expected.reject { |text| last_text.includes?(text) }
      message = [
        "Timed out after #{timeout} waiting for the #{label} pane.",
        "Expected to find: #{expected.map(&.inspect).join(", ")}",
        "Still missing: #{missing.map(&.inspect).join(", ")}",
        "Last #{label} pane capture:",
        last_text.empty? ? "(empty)" : last_text,
      ]
      message << "Last pane capture error: #{capture_error}" if capture_error
      fail_with_diagnostics(message.join("\n"))
    end

    private def expect_output(*expected : String, timeout : Time::Span = 5.seconds) : Nil
      expect_pane(output_pane, "output", expected.to_a, timeout)
    end

    private def expect_input(*expected : String, timeout : Time::Span = 5.seconds) : Nil
      expect_pane(input_pane, "input", expected.to_a, timeout)
    end

    private def expect_output_without(marker : String) : Nil
      actual = pane_text(output_pane)
      return unless actual.includes?(marker)

      fail_with_diagnostics(
        "Expected the output pane not to contain #{marker.inspect}, but it did.\n" \
        "Output pane contents:\n#{actual}"
      )
    rescue ex
      raise ex if ex.message.to_s.includes?("scenario: #{name}")

      fail_with_diagnostics(
        "Could not verify that the output pane excludes #{marker.inspect}: " \
        "#{ex.class}: #{ex.message}"
      )
    end
  end
end
