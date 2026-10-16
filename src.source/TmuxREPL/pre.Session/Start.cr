def start : Nil
  if tmux?("has-session", "-t", @name)
    Process.run("tmux", ["attach-session", "-t", @name])
    return
  else
    create
  end
end

def create
  Process.run("tmux", ["new-session", "-s", @name, "./bin/tmux.repl.input"])
  setup_right_pane
end

# Splits the window horizontally to create a right-hand output pane
def setup_right_pane
  stdout = IO::Memory.new
  # Split window horizontally (-h), detached (-d), return target data (-P -F)
  status = Process.run(
    "tmux", 
    ["split-window", "-h", "-d", "-P", "-F", "\\\#{pane_tty}"], 
    output: stdout
  )

  unless status.success?
    raise "Failed to split Tmux window. Make sure Tmux is operational."
  end

  # Parse the target pane's pseudo-terminal path and hook into it
  right_pane_tty = stdout.to_s.strip
  @output_pane = File.open(right_pane_tty, "w")
end
