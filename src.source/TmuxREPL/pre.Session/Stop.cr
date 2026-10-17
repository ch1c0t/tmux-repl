def stop : Nil
  begin
    server = ENV["TMUX"]?.nil? ? Tmux::Server.new : Tmux::Server.from_env
    server.cmd("kill-session", "-t", @name)
  rescue Tmux::Error
  ensure
    FileUtils.rm_rf(state_dir)
  end
end
