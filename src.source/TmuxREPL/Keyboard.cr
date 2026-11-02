enum Action
  ToggleOutputView
  SelectPrevious
  SelectNext
  SubmitInput
end

struct Binding
  getter key : Char
  getter action : Action
  getter label : String
  getter description : String

  def initialize(@key : Char, @action : Action, @label : String, @description : String)
  end

  def help_line : String
    "#{label.ljust(12)}#{description}"
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
    "#{label.ljust(12)}#{description}"
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

SEQUENCE_BINDINGS = [
  SequenceBinding.new("Ctrl+Up", Action::SelectPrevious, "Ctrl+Up", "Select the previous input."),
  SequenceBinding.new("Ctrl+Down", Action::SelectNext, "Ctrl+Down", "Select the next input."),
]

def self.binding_for(key : Char) : Binding?
  BINDINGS.find { |binding| binding.key == key }
end

def self.sequence_binding_for(key : String) : SequenceBinding?
  SEQUENCE_BINDINGS.find { |binding| binding.key == key }
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
