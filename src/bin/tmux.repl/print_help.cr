HELP_MESSAGE = <<-S
tmux.repl - a two-pane command REPL in tmux

Usage:
  tmux.repl start [SESSION]   Start or attach to a REPL session
  tmux.repl stop [SESSION]    Stop a session and remove its state
  tmux.repl --help            Show this help

The executables have separate responsibilities:
  tmux.repl         Lifecycle manager for the tmux session
  tmux.repl.input   Reply-based left-pane input frontend
  tmux.repl.output  Right-pane output viewer
  tmux.repl.worker  PTY command executor

The input frontend assigns an ID to each submitted command. In the left pane:
  :list             List inputs and the currently selected input
  :select ID        Display only that input's output in the right pane
  :prev / :next     Select the previous or next input
  :help             Show these controls

The frontends and worker exchange commands, selection events, output and exit
statuses through per-session durable LavinMQ streams. A custom interactive
command passed to TmuxREPL::Session is still supported and is displayed through
a log-following output pane.

Environment:
  TMUX_REPL_SESSION          Default session name
  XDG_STATE_HOME             State directory base
  LAVINMQ_AMQP_UNIXSOCKET     Required LavinMQ AMQP Unix socket

Requires tmux, the four tmux.repl executables, and LavinMQ.
S

def print_help
  puts HELP_MESSAGE
end
