def start : Nil
  if tmux?("has-session", "-t", @name)
    Process.run("tmux", ["attach-session", "-t", @name])
    return
  end

  dir = state_dir
  log = File.join(dir, "output.log")
  created = false

  begin
    FileUtils.mkdir_p(dir)
    File.write(log, "")

    input = "#{shell_quote(repl_executable)} --repl #{shell_quote(log)}"
    output = "#{shell_quote(show_executable)} #{shell_quote(log)}"
    raise "Could not start tmux session" unless tmux?("new-session", "-d", "-s", @name, input)
    created = true
    raise "Could not create output pane" unless tmux?("split-window", "-h", "-t", @name, output)
    raise "Could not select tmux layout" unless tmux?("select-layout", "-t", @name, "even-horizontal")
    raise "Could not focus input pane" unless tmux?("select-pane", "-t", "#{@name}:0.0")
    raise "Could not attach to tmux session" unless Process.run("tmux", ["attach-session", "-t", @name]).success?
  rescue ex
    tmux?("kill-session", "-t", @name) if created
    FileUtils.rm_rf(dir)
    STDERR.puts "tmux.repl: #{ex.message}"
    raise ex
  end
end
