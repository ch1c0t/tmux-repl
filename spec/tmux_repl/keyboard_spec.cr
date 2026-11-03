require "../../src/tmux_repl"

describe TmuxREPL::Keyboard do
  it "resolves a key to its semantic action" do
    TmuxREPL::Keyboard.action_for('\u0007').should eq(
      TmuxREPL::Keyboard::Action::ToggleOutputView
    )
  end

  it "keeps Ctrl+Up and Ctrl+Down as the primary input-selection bindings" do
    previous = TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Up").not_nil!
    following = TmuxREPL::Keyboard.sequence_binding_for("Ctrl+Down").not_nil!

    previous.action.should eq(TmuxREPL::Keyboard::Action::SelectPrevious)
    following.action.should eq(TmuxREPL::Keyboard::Action::SelectNext)
    TmuxREPL::Keyboard.label_for(previous.action).should eq("Ctrl+Up")
    TmuxREPL::Keyboard.label_for(following.action).should eq("Ctrl+Down")
  end

  it "provides Alt+K and Alt+J as aliases for input selection" do
    previous = TmuxREPL::Keyboard.sequence_binding_for("Alt+K").not_nil!
    following = TmuxREPL::Keyboard.sequence_binding_for("Alt+J").not_nil!

    previous.action.should eq(TmuxREPL::Keyboard::Action::SelectPrevious)
    following.action.should eq(TmuxREPL::Keyboard::Action::SelectNext)
    TmuxREPL::Keyboard.label_for(previous.action).should eq("Ctrl+Up")
    TmuxREPL::Keyboard.label_for(following.action).should eq("Ctrl+Down")
  end

  it "maps output arrow and page keys to scroll actions" do
    TmuxREPL::Keyboard.output_sequence_binding_for("\e[A").not_nil!.action.should eq(
      TmuxREPL::Keyboard::Action::ScrollUp
    )
    TmuxREPL::Keyboard.output_sequence_binding_for("\e[B").not_nil!.action.should eq(
      TmuxREPL::Keyboard::Action::ScrollDown
    )
    TmuxREPL::Keyboard.output_sequence_binding_for("\e[5~").not_nil!.action.should eq(
      TmuxREPL::Keyboard::Action::ScrollPageUp
    )
    TmuxREPL::Keyboard.output_sequence_binding_for("\e[6~").not_nil!.action.should eq(
      TmuxREPL::Keyboard::Action::ScrollPageDown
    )
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
      "Ctrl+Down   Select the next input.\n" \
      "Alt+K       Also select the previous input.\n" \
      "Alt+J       Also select the next input."
    )
  end
end
