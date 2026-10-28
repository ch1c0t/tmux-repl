# tmux-repl

A reusable two-pane Tmux REPL library and command-line tools, implemented in Crystal.

The `tmux.repl` executable manages the Tmux session. The left and right panes run
separate frontends, while a background PTY worker executes shell commands. The
processes are isolated so `reply` and `crystal.pty` are never imported by the same
executable.

## Executable roles

- `tmux.repl` creates, activates, and stops a named two-pane session.
- `tmux.repl.input` uses `Reply::Reader` in the left pane and publishes commands.
- `tmux.repl.output` renders the selected input and only its associated output.
- `tmux.repl.worker` executes commands through `PTY::Session` and publishes output.

Build all four executables with:

```sh
shards build
```

Start a REPL session with `tmux.repl start [SESSION]`; stop it with
`tmux.repl stop [SESSION]`.

When the left pane is active, submit shell commands as usual. Each input gets an
ID. Use these controls in the left pane to select which input is shown on the right:

```text
:list       List submitted inputs
:select ID  Display the output associated with a specific input
:prev       Select the previous input
:next       Select the next input
:help       Show these controls
```

## Tmux REPL library

Require `tmux_repl` to create a named two-pane REPL session from Crystal code:

```crystal
require "tmux_repl"

TmuxREPL::Session.new("shell").start
```

Pass a command argument array to run a native interactive REPL instead. Its
pane output is copied to a session log and followed in the right pane:

```crystal
require "tmux_repl"

TmuxREPL::Session.new("python", command: ["python3", "-i"]).start
```

Call `.stop` on a `TmuxREPL::Session` with the same name to stop the session.
When launched inside tmux, `.start` switches the current client to the REPL
session; when launched outside tmux, it attaches a client. Use
`.start(focus: false)` to create or ensure the session without attaching or
switching clients.

## LavinMQ streams

Each shell-command session uses two durable LavinMQ streams:
`tmux.repl.<session>.commands` and `tmux.repl.<session>.events`. Stream messages
include the session name, input sequence, timestamp, and command or output data.
Set `LAVINMQ_AMQP_UNIXSOCKET` to the Unix socket path exposed by LavinMQ; the
REPL uses [global-amqp_channel](https://github.com/ch1c0t/crystal.global-amqp_channel)
for AMQP communication.

## Crystal Tmux API

The shard also exposes a top-level `Tmux` module with an object model inspired
by [libtmux](https://github.com/tmux-python/libtmux):

```crystal
require "tmux"

server = Tmux::Server.new
session = server.new_session("demo", detached: true)
window = session.active_window
pane = window.active_pane

pane.send_keys("echo hello")
sleep 0.1
puts pane.capture_pane.join("\n")
```

The core API covers server, session, window, and pane traversal; creating
sessions and windows; splitting panes; sending keys; capturing pane output;
self-location through tmux environment variables; and raw command execution.

## Development

```sh
shards install
bundle exec rake
crystal spec
```

The API end-to-end spec starts a separate Tmux server using a unique socket.