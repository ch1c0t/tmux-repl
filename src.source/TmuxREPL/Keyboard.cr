enum Action
  ToggleOutputView
  ToggleOutputList
  ToggleOutputWrap
  ToggleOutputZoom
  YankOutput
  SelectPrevious
  SelectNext
  SubmitInput
  ScrollUp
  ScrollDown
  ScrollPageUp
  ScrollPageDown
  ScrollHorizontalLeft
  ScrollHorizontalRight
  ScrollHorizontalStart
  ScrollHorizontalEnd
end

struct Binding
  getter key : Char
  getter action : Action
  getter label : String
  getter description : String

  def initialize(@key : Char, @action : Action, @label : String, @description : String)
  end

  def help_line : String
    "#{label.ljust(16)}#{description}"
  end
end

struct SequenceBinding
  getter key : String
  getter action : Action
  getter label : String
  getter description : String

  def initialize(@key : String, @action : Action, @label : String, @description : String)
  end

  def help_line : String
    "#{label.ljust(16)}#{description}"
  end
end

BINDINGS = [
  Binding.new(
    '\u0007',
    Action::ToggleOutputView,
    "Ctrl+G",
    "Toggle stripped/raw output from either pane."
  ),
  Binding.new(
    '\u000c',
    Action::ToggleOutputList,
    "Ctrl+L",
    "Toggle the available-outputs list from either pane."
  ),
  Binding.new(
    '\u0017',
    Action::ToggleOutputWrap,
    "Ctrl+W",
    "Toggle wrapped/unwrapped output from either pane."
  ),
]

# Ctrl+Up/Down are the primary input-selection bindings. Alt+K/J are aliases.
SEQUENCE_BINDINGS = [
  SequenceBinding.new("Ctrl+Up", Action::SelectPrevious, "Ctrl+Up", "Select the previous input."),
  SequenceBinding.new("Ctrl+Down", Action::SelectNext, "Ctrl+Down", "Select the next input."),
  SequenceBinding.new("Alt+K", Action::SelectPrevious, "Alt+K", "Also select the previous input."),
  SequenceBinding.new("Alt+J", Action::SelectNext, "Alt+J", "Also select the next input."),
  SequenceBinding.new("Alt+Up", Action::ScrollUp, "Alt+Up", "Scroll output up one line from either pane."),
  SequenceBinding.new("Alt+Down", Action::ScrollDown, "Alt+Down", "Scroll output down one line from either pane."),
  SequenceBinding.new("Alt+PageUp", Action::ScrollPageUp, "Alt+PageUp", "Scroll output up one page from either pane."),
  SequenceBinding.new("Alt+PageDown", Action::ScrollPageDown, "Alt+PageDown", "Scroll output down one page from either pane."),
  SequenceBinding.new("Alt+Left", Action::ScrollHorizontalLeft, "Alt+Left", "Scroll an unwrapped line left."),
  SequenceBinding.new("Alt+Right", Action::ScrollHorizontalRight, "Alt+Right", "Scroll an unwrapped line right."),
  SequenceBinding.new("Alt+Home", Action::ScrollHorizontalStart, "Alt+Home", "Jump to the start of an unwrapped line."),
  SequenceBinding.new("Alt+End", Action::ScrollHorizontalEnd, "Alt+End", "Jump to the end of an unwrapped line."),
  SequenceBinding.new("Alt+Z", Action::ToggleOutputZoom, "Alt+Z", "Zoom or restore the Output pane from either pane."),
  SequenceBinding.new("Alt+Y", Action::YankOutput, "Alt+Y", "Yank the current output to the X11 clipboard and primary selection."),
]

# xterm modifier parameter 3 represents Alt combined with the key.
INPUT_ACTION_SEQUENCES = {
  "\ez"       => "Alt+Z",
  "\ey"       => "Alt+Y",
  "\e[121;3u" => "Alt+Y",
  "\e[122;3u" => "Alt+Z",
  "\e[1;3A" => "Alt+Up",
  "\e[1;3B" => "Alt+Down",
  "\e[5;3~" => "Alt+PageUp",
  "\e[6;3~" => "Alt+PageDown",
  "\e[1;3D" => "Alt+Left",
  "\e[1;3C" => "Alt+Right",
  "\e[1;3H" => "Alt+Home",
  "\e[1;3F" => "Alt+End",
  "\e\e[A"  => "Alt+Up",
  "\e\e[B"  => "Alt+Down",
  "\e\e[5~" => "Alt+PageUp",
  "\e\e[6~" => "Alt+PageDown",
  "\e\e[D"  => "Alt+Left",
  "\e\e[C"  => "Alt+Right",
  "\e\e[H"  => "Alt+Home",
  "\e\e[F"  => "Alt+End",
}

INPUT_SEQUENCE_STRINGS = [
  "\ez", "\e[122;3u",
  "\ey", "\e[121;3u",
  "\ek", "\ej", "\e[107;3u", "\e[106;3u",
  "\e[1;5A", "\e[1;5B",
  "\e[1;3A", "\e[1;3B", "\e[5;3~", "\e[6;3~",
  "\e[1;3D", "\e[1;3C", "\e[1;3H", "\e[1;3F",
  "\e\e[A", "\e\e[B", "\e\e[5~", "\e\e[6~",
  "\e\e[D", "\e\e[C", "\e\e[H", "\e\e[F",
]

# Unmodified keys and their Alt-modified equivalents are accepted in Output.
OUTPUT_SEQUENCE_BINDINGS = {
  "\ez"       => SequenceBinding.new("Alt+Z", Action::ToggleOutputZoom, "Alt+Z", "Zoom or restore the Output pane."),
  "\e[122;3u" => SequenceBinding.new("Alt+Z", Action::ToggleOutputZoom, "Alt+Z", "Zoom or restore the Output pane."),
  "\ey"       => SequenceBinding.new("Alt+Y", Action::YankOutput, "Alt+Y", "Yank the current output to the X11 clipboard and primary selection."),
  "\e[121;3u" => SequenceBinding.new("Alt+Y", Action::YankOutput, "Alt+Y", "Yank the current output to the X11 clipboard and primary selection."),
  "\e[A"    => SequenceBinding.new("Up", Action::ScrollUp, "Up", "Scroll output up one line."),
  "\e[B"    => SequenceBinding.new("Down", Action::ScrollDown, "Down", "Scroll output down one line."),
  "\e[5~"   => SequenceBinding.new("PageUp", Action::ScrollPageUp, "PageUp", "Scroll output up one page."),
  "\e[6~"   => SequenceBinding.new("PageDown", Action::ScrollPageDown, "PageDown", "Scroll output down one page."),
  "\e[D"    => SequenceBinding.new("Left", Action::ScrollHorizontalLeft, "Left", "Scroll an unwrapped output line left."),
  "\e[C"    => SequenceBinding.new("Right", Action::ScrollHorizontalRight, "Right", "Scroll an unwrapped output line right."),
  "\e[H"    => SequenceBinding.new("Home", Action::ScrollHorizontalStart, "Home", "Jump to the start of an unwrapped line."),
  "\e[F"    => SequenceBinding.new("End", Action::ScrollHorizontalEnd, "End", "Jump to the end of an unwrapped line."),
  "\e[1;3A" => SequenceBinding.new("Alt+Up", Action::ScrollUp, "Alt+Up", "Scroll output up one line."),
  "\e[1;3B" => SequenceBinding.new("Alt+Down", Action::ScrollDown, "Alt+Down", "Scroll output down one line."),
  "\e[5;3~" => SequenceBinding.new("Alt+PageUp", Action::ScrollPageUp, "Alt+PageUp", "Scroll output up one page."),
  "\e[6;3~" => SequenceBinding.new("Alt+PageDown", Action::ScrollPageDown, "Alt+PageDown", "Scroll output down one page."),
  "\e[1;3D" => SequenceBinding.new("Alt+Left", Action::ScrollHorizontalLeft, "Alt+Left", "Scroll an unwrapped output line left."),
  "\e[1;3C" => SequenceBinding.new("Alt+Right", Action::ScrollHorizontalRight, "Alt+Right", "Scroll an unwrapped output line right."),
  "\e[1;3H" => SequenceBinding.new("Alt+Home", Action::ScrollHorizontalStart, "Alt+Home", "Jump to the start of an unwrapped line."),
  "\e[1;3F" => SequenceBinding.new("Alt+End", Action::ScrollHorizontalEnd, "Alt+End", "Jump to the end of an unwrapped line."),
  "\e\e[A"  => SequenceBinding.new("Alt+Up", Action::ScrollUp, "Alt+Up", "Scroll output up one line."),
  "\e\e[B"  => SequenceBinding.new("Alt+Down", Action::ScrollDown, "Alt+Down", "Scroll output down one line."),
  "\e\e[5~" => SequenceBinding.new("Alt+PageUp", Action::ScrollPageUp, "Alt+PageUp", "Scroll output up one page."),
  "\e\e[6~" => SequenceBinding.new("Alt+PageDown", Action::ScrollPageDown, "Alt+PageDown", "Scroll output down one page."),
  "\e\e[D"  => SequenceBinding.new("Alt+Left", Action::ScrollHorizontalLeft, "Alt+Left", "Scroll an unwrapped output line left."),
  "\e\e[C"  => SequenceBinding.new("Alt+Right", Action::ScrollHorizontalRight, "Alt+Right", "Scroll an unwrapped output line right."),
  "\e\e[H"  => SequenceBinding.new("Alt+Home", Action::ScrollHorizontalStart, "Alt+Home", "Jump to the start of an unwrapped line."),
  "\e\e[F"  => SequenceBinding.new("Alt+End", Action::ScrollHorizontalEnd, "Alt+End", "Jump to the end of an unwrapped line."),
}

def self.binding_for(key : Char) : Binding?
  BINDINGS.find { |binding| binding.key == key }
end

def self.sequence_binding_for(key : String) : SequenceBinding?
  SEQUENCE_BINDINGS.find { |binding| binding.key == key }
end

def self.output_sequence_binding_for(sequence : String) : SequenceBinding?
  OUTPUT_SEQUENCE_BINDINGS[sequence]?
end

def self.output_sequence_match(input : String) : Tuple(String, SequenceBinding)?
  OUTPUT_SEQUENCE_BINDINGS.each do |sequence, binding|
    return {sequence, binding} if input.starts_with?(sequence)
  end
end

def self.output_sequence_prefix?(input : String) : Bool
  OUTPUT_SEQUENCE_BINDINGS.keys.any? { |sequence| sequence.starts_with?(input) }
end

def self.action_for(key : Char) : Action?
  if binding = binding_for(key)
    binding.action
  end
end

def self.label_for(action : Action) : String
  BINDINGS.each do |binding|
    return binding.label if binding.action == action
  end
  SEQUENCE_BINDINGS.each do |binding|
    return binding.label if binding.action == action
  end
  raise ArgumentError.new("No keyboard binding registered for #{action}")
end

def self.help_text : String
  toggle_help = "Ctrl+G raw · Ctrl+L list · Ctrl+W wrap · Alt+Z zoom · Alt+Y yank Output"
  horizontal_help = "Alt+←/→ scroll · Alt+Home/End jump"
  bindings = BINDINGS.reject do |binding|
    binding.action == Action::ToggleOutputView || binding.action == Action::ToggleOutputList || binding.action == Action::ToggleOutputWrap
  end
  horizontal_bindings = SEQUENCE_BINDINGS.reject do |binding|
    binding.action == Action::ScrollHorizontalLeft ||
      binding.action == Action::ScrollHorizontalRight ||
      binding.action == Action::ScrollHorizontalStart ||
      binding.action == Action::ScrollHorizontalEnd ||
      binding.action == Action::ToggleOutputZoom ||
      binding.action == Action::YankOutput
  end

  ([toggle_help, horizontal_help] + bindings.map(&.help_line) + horizontal_bindings.map(&.help_line)).join("\n")
end
