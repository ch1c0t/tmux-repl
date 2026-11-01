require "../../src/tmux_repl"

describe TmuxREPL::Keyboard do
  it "resolves a key to its semantic action" do
    TmuxREPL::Keyboard.action_for('\u0007').should eq(
      TmuxREPL::Keyboard::Action::ToggleOutputView
    )
  end

  it "does not assign actions to unbound keys" do
    TmuxREPL::Keyboard.action_for('x').should be_nil
  end

  it "provides the label and help text from the binding definition" do
    action = TmuxREPL::Keyboard::Action::ToggleOutputView

    TmuxREPL::Keyboard.label_for(action).should eq("Ctrl+G")
    TmuxREPL::Keyboard.help_text.should eq(
      "Ctrl+G      Toggle stripped/raw output from either pane."
    )
  end
end
