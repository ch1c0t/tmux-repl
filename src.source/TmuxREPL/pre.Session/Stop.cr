def stop : Nil
  begin
    server = ENV["TMUX"]? ? Tmux::Server.from_env : Tmux::Server.new
    server.cmd("kill-session", "-t", @name)
  rescue Tmux::Error
  ensure
    FileUtils.rm_rf(state_dir)
  end
end
