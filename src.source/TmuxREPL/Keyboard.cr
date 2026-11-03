enum Action
  ToggleOutputView
  SelectPrevious
  SelectNext
  SubmitInput
  ScrollUp
  ScrollDown
  ScrollPageUp
  ScrollPageDown
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
]

# xterm modifier parameter 3 represents Alt combined with the key.
INPUT_SCROLL_SEQUENCES = {
  "\e[1;3A" => "Alt+Up",
  "\e[1;3B" => "Alt+Down",
  "\e[5;3~" => "Alt+PageUp",
  "\e[6;3~" => "Alt+PageDown",
  "\e\e[A"  => "Alt+Up",
  "\e\e[B"  => "Alt+Down",
  "\e\e[5~" => "Alt+PageUp",
  "\e\e[6~" => "Alt+PageDown",
}

INPUT_SEQUENCE_STRINGS = [
  "\ek", "\ej", "\e[107;3u", "\e[106;3u",
  "\e[1;5A", "\e[1;5B",
  "\e[1;3A", "\e[1;3B", "\e[5;3~", "\e[6;3~",
  "\e\e[A", "\e\e[B", "\e\e[5~", "\e\e[6~",
]

# Unmodified keys and their Alt-modified equivalents are accepted in Output.
OUTPUT_SEQUENCE_BINDINGS = {
  "\e[A"    => SequenceBinding.new("Up", Action::ScrollUp, "Up", "Scroll output up one line."),
  "\e[B"    => SequenceBinding.new("Down", Action::ScrollDown, "Down", "Scroll output down one line."),
  "\e[5~"   => SequenceBinding.new("PageUp", Action::ScrollPageUp, "PageUp", "Scroll output up one page."),
  "\e[6~"   => SequenceBinding.new("PageDown", Action::ScrollPageDown, "PageDown", "Scroll output down one page."),
  "\e[1;3A" => SequenceBinding.new("Alt+Up", Action::ScrollUp, "Alt+Up", "Scroll output up one line."),
  "\e[1;3B" => SequenceBinding.new("Alt+Down", Action::ScrollDown, "Alt+Down", "Scroll output down one line."),
  "\e[5;3~" => SequenceBinding.new("Alt+PageUp", Action::ScrollPageUp, "Alt+PageUp", "Scroll output up one page."),
  "\e[6;3~" => SequenceBinding.new("Alt+PageDown", Action::ScrollPageDown, "Alt+PageDown", "Scroll output down one page."),
  "\e\e[A"  => SequenceBinding.new("Alt+Up", Action::ScrollUp, "Alt+Up", "Scroll output up one line."),
  "\e\e[B"  => SequenceBinding.new("Alt+Down", Action::ScrollDown, "Alt+Down", "Scroll output down one line."),
  "\e\e[5~" => SequenceBinding.new("Alt+PageUp", Action::ScrollPageUp, "Alt+PageUp", "Scroll output up one page."),
  "\e\e[6~" => SequenceBinding.new("Alt+PageDown", Action::ScrollPageDown, "Alt+PageDown", "Scroll output down one page."),
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
  (BINDINGS.map(&.help_line) + SEQUENCE_BINDINGS.map(&.help_line)).join("\n")
end
