private def watch_keyboard(view : View, terminal_mode : TerminalMode) : Nil
  return unless terminal_mode.enable

  spawn do
    begin
      while key = STDIN.read_char
        next unless key == 'v' || key == 'V'

        view.toggle_view
        view.render
      end
    rescue IO::Error
      # The pane may close while the keyboard reader is waiting.
    ensure
      terminal_mode.restore
    end
  end
end
