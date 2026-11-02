private def watch_keyboard(
  dispatcher : TmuxREPL::Keyboard::Dispatcher,
  terminal_mode : TmuxREPL::TerminalMode
) : Nil
  return unless terminal_mode.enable

  spawn do
    begin
      while key = STDIN.read_char
        dispatcher.enqueue(key)
      end
    rescue IO::Error
      # The pane may close while the keyboard reader is waiting.
    ensure
      terminal_mode.restore
    end
  end
end
