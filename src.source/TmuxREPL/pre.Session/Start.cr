def start : Nil
  server = Tmux::Server.new
  if server.cmd("has-session", "-t", @name).success?
    server.session(@name).attach(unset_tmux: true)
    return
  end

  dir = state_dir
  log = File.join(dir, "output.log")
  session : Tmux::Session? = nil

  begin
    FileUtils.mkdir_p(dir)
    File.write(log, "")

    session = server.new_session(name: @name, detached: true)
    window = session.active_window
    input_pane = window.active_pane
    output_pane = input_pane.split(:right, detached: true)
    window.select_layout("even-horizontal")

    input = "#{shell_quote(repl_executable)} --repl #{shell_quote(log)}"
    output = "#{shell_quote(show_executable)} #{shell_quote(log)}"
    input_pane.send_keys(input, literal: true)
    output_pane.send_keys(output, literal: true)
    input_pane.select

    session.attach(unset_tmux: true)
  rescue ex
    begin
      if active_session = session
        active_session.kill
      else
        server.cmd("kill-session", "-t", @name)
      end
    rescue Tmux::Error
    end
    FileUtils.rm_rf(dir)
    STDERR.puts "tmux.repl: #{ex.message}"
    raise ex
  end
end
