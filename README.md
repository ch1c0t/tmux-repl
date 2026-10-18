# tmux-repl

A reusable two-pane Tmux REPL library and command-line tools, implemented in Crystal.

The `tmux.repl` executable provides a shell-command REPL. The library can also
launch native interactive REPLs, pipe their pane output into a session log, and
follow that log in the right pane with `tmux.show`.

## Tmux REPL library

Require `tmux_repl` to create a named two-pane REPL session from Crystal code.
The default session runs the existing shell-command REPL:

```crystal
require "tmux_repl"

TmuxREPL::Session.new("shell").start
```

Pass a command argument array to run a native interactive REPL instead. Its
pane output is copied to the session log and followed in the right pane:

```crystal
require "tmux_repl"

TmuxREPL::Session.new("python", command: ["python3", "-i"]).start
TmuxREPL::Session.crystal_interpreter.start
```

The Crystal preset runs `ic` (I3oris/ic, an interface to the Crystal interpreter); its session
name defaults to `crystal`. Override the name or executable when needed:

```crystal
TmuxREPL::Session.crystal_interpreter("crystal-dev", "/opt/crystal/bin/ic").start
```

Call `.stop` on a `TmuxREPL::Session` with the same name to stop the session.
When launched inside tmux, `.start` switches the current client to the REPL
session; when launched outside tmux, it attaches a client. Use
`.start(focus: false)` to create or ensure the session without attaching or
switching clients, which is useful when managing REPLs from another program.

## Crystal API

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

See [docs/api.md](docs/api.md) for the API guide.

## Development

```sh
shards install
shards build
crystal spec
```

The API's end-to-end spec starts a separate tmux server using a unique socket.
