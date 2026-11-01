private def watch_keyboard(view : View, terminal_mode : TerminalMode) : Nil
  return unless terminal_mode.enable

  spawn do
    begin
      while key = STDIN.read_char
        case TmuxREPL::Keyboard.action_for(key)
        when TmuxREPL::Keyboard::Action::ToggleOutputView
          view.toggle_view
          view.render
        end
      end
    rescue IO::Error
      # The pane may close while the keyboard reader is waiting.
    ensure
      terminal_mode.restore
    end
  end
end
