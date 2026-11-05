require "../../src/tmux_repl"

describe TmuxREPL::Keyboard do
  it "resolves a key to its semantic action" do
    TmuxREPL::Keyboard.action_for('\u0007').should eq(
      TmuxREPL::Keyboard::Action::ToggleOutputView
    )
  end


  it "maps Ctrl+W to the wrapped/unwrapped output toggle" do
    action = TmuxREPL::Keyboard::Action::ToggleOutputWrap

    TmuxREPL::Keyboard.action_for('\u0017').should eq(action)
    TmuxREPL::Keyboard.label_for(action).should eq("Ctrl+W")
  end

  it "maps Alt+Z to the shared Output-pane zoom toggle" do
    action = TmuxREPL::Keyboard::Action::ToggleOutputZoom
    binding = TmuxREPL::Keyboard.sequence_binding_for("Alt+Z").not_nil!

    binding.action.should eq(action)
    TmuxREPL::Keyboard.label_for(action).should eq("Alt+Z")
    TmuxREPL::Keyboard.output_sequence_binding_for("\ez").not_nil!.action.should eq(action)
    TmuxREPL::Keyboard.output_sequence_binding_for("\e[122;3u").not_nil!.action.should eq(action)
  end

  it "maps Ctrl+L to the available-outputs list toggle" do
    action = TmuxREPL::Keyboard::Action::ToggleOutputList

    TmuxREPL::Keyboard.action_for('\u000c').should eq(action)
    TmuxREPL::Keyboard.label_for(action).should eq("Ctrl+L")
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

  it "maps Alt arrows and page keys to shared scroll actions" do
    {
      "Alt+Up"       => TmuxREPL::Keyboard::Action::ScrollUp,
      "Alt+Down"     => TmuxREPL::Keyboard::Action::ScrollDown,
      "Alt+PageUp"   => TmuxREPL::Keyboard::Action::ScrollPageUp,
      "Alt+PageDown" => TmuxREPL::Keyboard::Action::ScrollPageDown,
      "Alt+Left"     => TmuxREPL::Keyboard::Action::ScrollHorizontalLeft,
      "Alt+Right"    => TmuxREPL::Keyboard::Action::ScrollHorizontalRight,
      "Alt+Home"     => TmuxREPL::Keyboard::Action::ScrollHorizontalStart,
      "Alt+End"      => TmuxREPL::Keyboard::Action::ScrollHorizontalEnd,
    }.each do |key, action|
      TmuxREPL::Keyboard.sequence_binding_for(key).not_nil!.action.should eq(action)
    end
  end

  it "maps plain and Alt-modified output sequences to scroll actions" do
    {
      "\ez"       => TmuxREPL::Keyboard::Action::ToggleOutputZoom,
      "\e[122;3u" => TmuxREPL::Keyboard::Action::ToggleOutputZoom,
      "\e[A"    => TmuxREPL::Keyboard::Action::ScrollUp,
      "\e[B"    => TmuxREPL::Keyboard::Action::ScrollDown,
      "\e[5~"   => TmuxREPL::Keyboard::Action::ScrollPageUp,
      "\e[6~"   => TmuxREPL::Keyboard::Action::ScrollPageDown,
      "\e[D"    => TmuxREPL::Keyboard::Action::ScrollHorizontalLeft,
      "\e[C"    => TmuxREPL::Keyboard::Action::ScrollHorizontalRight,
      "\e[H"    => TmuxREPL::Keyboard::Action::ScrollHorizontalStart,
      "\e[F"    => TmuxREPL::Keyboard::Action::ScrollHorizontalEnd,
      "\e[1;3A" => TmuxREPL::Keyboard::Action::ScrollUp,
      "\e[1;3B" => TmuxREPL::Keyboard::Action::ScrollDown,
      "\e[5;3~" => TmuxREPL::Keyboard::Action::ScrollPageUp,
      "\e[6;3~" => TmuxREPL::Keyboard::Action::ScrollPageDown,
      "\e[1;3D" => TmuxREPL::Keyboard::Action::ScrollHorizontalLeft,
      "\e[1;3C" => TmuxREPL::Keyboard::Action::ScrollHorizontalRight,
      "\e[1;3H" => TmuxREPL::Keyboard::Action::ScrollHorizontalStart,
      "\e[1;3F" => TmuxREPL::Keyboard::Action::ScrollHorizontalEnd,
      "\e\e[A"  => TmuxREPL::Keyboard::Action::ScrollUp,
      "\e\e[B"  => TmuxREPL::Keyboard::Action::ScrollDown,
      "\e\e[5~" => TmuxREPL::Keyboard::Action::ScrollPageUp,
      "\e\e[6~" => TmuxREPL::Keyboard::Action::ScrollPageDown,
      "\e\e[D"  => TmuxREPL::Keyboard::Action::ScrollHorizontalLeft,
      "\e\e[C"  => TmuxREPL::Keyboard::Action::ScrollHorizontalRight,
      "\e\e[H"  => TmuxREPL::Keyboard::Action::ScrollHorizontalStart,
      "\e\e[F"  => TmuxREPL::Keyboard::Action::ScrollHorizontalEnd,
    }.each do |sequence, action|
      TmuxREPL::Keyboard.output_sequence_binding_for(sequence).not_nil!.action.should eq(action)
    end
  end

  it "does not assign actions to unbound keys" do
    TmuxREPL::Keyboard.action_for('x').should be_nil
    TmuxREPL::Keyboard.sequence_binding_for("Alt+F9").should be_nil
  end

  it "provides the label and help text from the binding definitions" do
    action = TmuxREPL::Keyboard::Action::ToggleOutputView

    TmuxREPL::Keyboard.label_for(action).should eq("Ctrl+G")
    TmuxREPL::Keyboard.help_text.should eq(
      "Ctrl+G raw · Ctrl+L list · Ctrl+W wrap · Alt+Z zoom Output\n" \
      "Alt+←/→ scroll · Alt+Home/End jump\n" \
      "Ctrl+Up         Select the previous input.\n" \
      "Ctrl+Down       Select the next input.\n" \
      "Alt+K           Also select the previous input.\n" \
      "Alt+J           Also select the next input.\n" \
      "Alt+Up          Scroll output up one line from either pane.\n" \
      "Alt+Down        Scroll output down one line from either pane.\n" \
      "Alt+PageUp      Scroll output up one page from either pane.\n" \
      "Alt+PageDown    Scroll output down one page from either pane."
    )
  end
end
