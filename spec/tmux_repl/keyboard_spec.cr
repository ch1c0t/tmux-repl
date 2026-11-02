require "../../src/tmux_repl"

describe TmuxREPL::Keyboard do
  it "resolves a key to its semantic action" do
    TmuxREPL::Keyboard.action_for('\u0007').should eq(
      TmuxREPL::Keyboard::Action::ToggleOutputView
    )
  end

  it "maps Ctrl+Up and Ctrl+Down to adjacent input selection" do
    previous = TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Up").not_nil!
    next = TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Down").not_nil!

    previous.action.should eq(TmuxREPL::Keyboard::Action::SelectPrevious)
    next.action.should eq(TmuxREPL::Keyboard::Action::SelectNext)
    TmuxREPL::Keyboard.label_for(previous.action).should eq("Ctrl+Up")
    TmuxREPL::Keyboard.label_for(next.action).should eq("Ctrl+Down")
  end

  it "does not assign actions to unbound keys" do
    TmuxREPL::Keyboard.action_for('x').should be_nil
    TmuxREPL::Keyboard.sequence_binding_for("Alt+Up").should be_nil
  end

  it "provides the label and help text from the binding definitions" do
    action = TmuxREPL::Keyboard::Action::ToggleOutputView

    TmuxREPL::Keyboard.label_for(action).should eq("Ctrl+G")
    TmuxREPL::Keyboard.help_text.should eq(
      "Ctrl+G      Toggle stripped/raw output from either pane.\n" \
      "Ctrl+Up     Select the previous input.\n" \
      "Ctrl+Down   Select the next input."
    )
  end
end
