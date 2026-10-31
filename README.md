# tmux-repl

A reusable two-pane Tmux REPL library and command-line tools, implemented in Crystal.

The tmux.repl executable orchestrates a named Tmux session. The left and right
panes run separate frontends, while a background PTY worker executes shell
commands. The three companion executables are independent processes so reply
and crystal.pty are never imported by the same executable.

## Executable roles

- tmux.repl creates, activates, and stops a named two-pane session.
- tmux.repl.input reads and publishes commands in the left pane.
- tmux.repl.output renders the selected input and its associated output.
- tmux.repl.worker executes commands through PTY::Session and publishes output.

Build all four executables with:

    shards build

By default, the CLI prefers the companion executables beside the running
`tmux.repl` binary, then searches the invoking process's $PATH. Each companion
can be overridden independently. An override may be an executable path or a
command name found on $PATH.

For shell/CLI use, set any of:

    TMUX_REPL_INPUT_EXECUTABLE=/opt/tmux-repl/tmux.repl.input
    TMUX_REPL_OUTPUT_EXECUTABLE=/opt/tmux-repl/tmux.repl.output
    TMUX_REPL_WORKER_EXECUTABLE=/opt/tmux-repl/tmux.repl.worker

For library use, configure overrides on the DSL or Session:

    TmuxREPL.define("custom-shell") do |repl|
      repl.executables(
        input: "/opt/tmux-repl/tmux.repl.input",
        output: "/opt/tmux-repl/tmux.repl.output",
        worker: "/opt/tmux-repl/tmux.repl.worker"
      )
    end.start

An explicit DSL/Session override takes precedence over the corresponding
environment variable; environment variables take precedence over sibling and
$PATH discovery.

Start a REPL session with tmux.repl start [SESSION]; stop it with
tmux.repl stop [SESSION].

When the left pane is active, submit shell commands as usual. Each input gets an
ID. Use these controls in the left pane to select which input is shown on the right:

    :list       List submitted inputs
    :select ID  Display the output associated with a specific input
    :prev       Select the previous input
    :next       Select the next input
    :help       Show these controls

## Tmux REPL library and DSL

Require tmux_repl to define a named REPL from Crystal code. The block configures
the command to launch, environment variables, and working directory:

    require "tmux_repl"

    python = TmuxREPL.define("python") do |repl|
      repl.command "python3", "-i"
      repl.env "PYTHONSTARTUP", File.expand_path("~/.pythonrc")
      repl.cwd Dir.home
    end

    python.start
    # ...
    python.stop

A definition without command uses the standard shell/PTY worker:

    TmuxREPL.define("shell") { |_repl| }.start

The lower-level TmuxREPL::Session API remains available:

    TmuxREPL::Session.new("shell").start
    TmuxREPL::Session.new("python", command: ["python3", "-i"]).start

Call stop on a definition or a session with the same name to stop it.
When launched inside tmux, start switches the current client to the REPL
session; when launched outside tmux, it attaches a client. Use
start(focus: false) to create or ensure the session without attaching or
switching clients.

## LavinMQ streams

Each shell-command session uses two durable LavinMQ streams:
tmux.repl.<session>.commands and tmux.repl.<session>.events. Stream messages
include the session name, input sequence, timestamp, and command or output data.
Set LAVINMQ_AMQP_UNIXSOCKET to the Unix socket path exposed by LavinMQ; the
REPL uses global-amqp_channel for AMQP communication.

## Development

    shards install
    bundle exec rake
    crystal spec

The API end-to-end spec starts a separate Tmux server using a unique socket.

### Tracing command latency

Start a new session with timing diagnostics enabled:

    TMUX_REPL_TRACE_TIMING=1 tmux.repl start latency-debug

Run a few commands, including the first one, then inspect
$XDG_STATE_HOME/tmux-repl/latency-debug/timing.log (or
$HOME/.local/state/tmux-repl/latency-debug/timing.log when
XDG_STATE_HOME is unset). The trace separates input publication, worker
delivery, PTY execution, output-event publication, and output-pane rendering.
Tracing is disabled by default.
