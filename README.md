# tmux-repl

A two-pane command REPL for tmux, implemented in Crystal.

The `tmux.repl` command runs an input REPL in the left pane. Results are
appended to a per-session log and followed by `tmux.show` in the right pane.

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
