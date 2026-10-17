HELP_MESSAGE = <<-S
tmux.show - follow a tmux.repl output log

Usage:
  tmux.show LOG

Displays the log from its first line and continuously follows appended output.
S

def print_help
  puts HELP_MESSAGE
end
