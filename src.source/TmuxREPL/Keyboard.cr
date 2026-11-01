enum Action
  ToggleOutputView
  SubmitInput
end

struct Binding
  getter key : Char
  getter action : Action
  getter label : String
  getter description : String

  def initialize(
    @key : Char,
    @action : Action,
    @label : String,
    @description : String
  )
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

def self.binding_for(key : Char) : Binding?
  BINDINGS.find { |binding| binding.key == key }
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

  raise ArgumentError.new("No keyboard binding registered for #{action}")
end

def self.help_text : String
  BINDINGS.map { |binding| binding.help_line }.join("\n")
end
