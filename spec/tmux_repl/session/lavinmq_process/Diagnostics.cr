module LavinMQProcess
  class Scenario
    private def diagnostic_details : String
      details = "input pane:\n#{pane_text(input_pane)}\noutput pane:\n#{pane_text(output_pane)}"

      begin
        channel = Global.amqp_channel
        commands = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(name))
        events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(name))
        details += "\ncommand stream messages: #{commands.message_count}"
        details += "\nevent stream messages: #{events.message_count}"
      rescue ex
        details += "\nqueue diagnostics failed: #{ex.message}"
      end

      details
    end

    private def expect_pane(
      pane : Tmux::Pane,
      expected : Array(String),
      timeout : Time::Span = 5.seconds
    ) : Nil
      return if pane_shows?(pane, expected, timeout, 25.milliseconds)

      raise "Timed out waiting for #{expected.join(", ")}.\n#{diagnostic_details}"
    end

    private def expect_output(*expected : String, timeout : Time::Span = 5.seconds) : Nil
      expect_pane(output_pane, expected.to_a, timeout)
    end

    private def expect_input(*expected : String, timeout : Time::Span = 5.seconds) : Nil
      expect_pane(input_pane, expected.to_a, timeout)
    end

    private def expect_output_without(marker : String) : Nil
      pane_text(output_pane).should_not contain(marker)
    end
  end
end
