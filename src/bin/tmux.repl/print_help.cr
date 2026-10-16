HELP_MESSAGE = <<-S
tmux.repl - a two-pane command REPL in tmux

Usage:
  tmux.repl start [SESSION]   Start or attach to a REPL session
  tmux.repl stop [SESSION]    Stop a session and remove its state
  tmux.repl --help            Show this help

Commands are entered in the left pane. The tmux.show executable runs
in the right pane and continuously displays command output and exit status.

Environment:
  TMUX_REPL_SESSION  Default session name (default: tmux-repl)
  XDG_STATE_HOME     State directory base (default: ~/.local/state)

Requires tmux, tmux.repl, tmux.show, and a POSIX /bin/sh.
S

def print_help
  puts HELP_MESSAGE
end
