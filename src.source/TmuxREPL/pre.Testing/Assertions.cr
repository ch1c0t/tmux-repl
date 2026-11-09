def expect_visible(
  *expected : String,
  timeout : Time::Span? = nil
) : Nil
  expect_visible_items(expected.to_a, timeout || @timeout)
end

def expect_output_without(marker : String) : Nil
  text = current_output
  raise "Output pane still contains #{marker.inspect}.\n#{text}" if text.includes?(marker)
end

def expect_selected_input(sequence : Int32) : Nil
  expect_visible("INPUT ##{sequence}")
end

def expect_zoomed(expected : Bool) : Nil
  found = wait_until do
    zoomed = output_pane.display_message("\#{window_zoomed_flag}") == "1"
    zoomed == expected && (!expected || output_pane.active?)
  end
  return if found

  actual = output_pane.display_message("\#{window_zoomed_flag}") == "1"
  raise "Expected Output pane zoomed=#{expected}, got #{actual}."
end

def select_pane(pane : Symbol) : Nil
  target = case pane
           when :input
             input_pane
           when :output
             output_pane
           else
             raise ArgumentError.new("pane must be :input or :output, got #{pane.inspect}")
           end
  target.select
end

def expect_active_pane(pane : Symbol) : Nil
  target = case pane
           when :input
             input_pane
           when :output
             output_pane
           else
             raise ArgumentError.new("pane must be :input or :output, got #{pane.inspect}")
           end

  return if wait_until { target.active? }

  actual = if input_pane.active?
    :input
  elsif output_pane.active?
    :output
  else
    :none
  end
  raise "Expected #{pane} pane to be active, got #{actual}."
end

def current_output : String
  pane_text(output_pane)
end
