def stop : Nil
  tmux?("kill-session", "-t", @name)
  FileUtils.rm_rf(state_dir)
end
