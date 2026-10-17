def stop : Nil
  begin
    Tmux::Server.new.cmd("kill-session", "-t", @name)
  rescue Tmux::Error
  ensure
    FileUtils.rm_rf(state_dir)
  end
end
