# Handle input-pane commands without submitting them to the worker.
private def handle_control(
  control : String,
  events : AMQP::Client::Queue,
  history : History
) : Bool
  if match = control.match(/\A:select\s+([0-9]+)\z/)
    target = match[1].to_u64
    if history.includes?(target)
      select_input(target, events, history)
    else
      puts "No input ##{target}. Use :list to see submitted inputs."
    end
    return true
  end

  case control
  when ":prev"
    if target = history.previous_sequence
      select_input(target, events, history)
    elsif history.selected_sequence
      puts "Already at the oldest input."
    else
      puts "No inputs have been submitted."
    end
    true
  when ":next"
    if target = history.next_sequence
      select_input(target, events, history)
    elsif history.selected_sequence
      puts "Already at the newest input."
    else
      puts "No inputs have been submitted."
    end
    true
  when ":list"
    if history.entries.empty?
      puts "No inputs have been submitted."
    else
      history.entries.each do |entry|
        marker = entry[0] == history.selected_sequence ? "*" : " "
        puts "#{marker} ##{entry[0]}: #{entry[1].lines.first? || entry[1]}"
      end
    end
    true
  when ":help"
    puts ":select ID  Show the output associated with an input."
    puts ":prev       Select the previous input."
    puts ":next       Select the next input."
    puts ":list       List submitted inputs."
    true
  else
    false
  end
end

private def select_input(
  sequence : UInt64,
  events : AMQP::Client::Queue,
  history : History
) : Nil
  TmuxREPL.publish_event(events, "select", @session_name, sequence)
  history.select(sequence)
  puts "Selected input ##{sequence}."
end
