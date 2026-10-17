# Crystal tmux API

This shard also exposes a small object-oriented API in the top-level `Tmux`
module, inspired by the server/session/window/pane model in
[libtmux](https://github.com/tmux-python/libtmux).

## Example

```crystal
require "tmux"

server = Tmux::Server.new
session = server.new_session("demo", detached: true)
window = session.new_window("logs", detached: true)
pane = window.active_pane

pane.send_keys("printf 'hello from tmux'")
sleep 0.1
puts pane.capture_pane.join("\n")

session.kill
```

## Objects

- `Tmux::Server` lists sessions, creates sessions, and exposes `cmd`/`run!`
  for raw tmux commands. Use `Server.new(socket_name: "test")` to isolate a server.
- `Tmux::Session` traverses windows, creates windows, attaches, renames, and kills.
- `Tmux::Window` traverses panes, splits, resizes, renames, and selects layouts.
- `Tmux::Pane` sends keys, captures screen contents, exposes common pane fields,
  and can be resolved with `Pane.from_env` inside a tmux pane.

Use `Tmux::Server.from_env`, `Tmux::Session.from_env`, `Tmux::Window.from_env`,
or `Tmux::Pane.from_env` for self-location inside tmux. Objects query tmux on
access, so values such as active windows and panes reflect current server state.

Commands are passed to `Process.run` as argument arrays rather than interpolated
into a shell command. `cmd` returns a `Tmux::CommandResult`; `run!` raises
`Tmux::CommandError` on nonzero exit status.

This is an initial core API, not a complete port of libtmux's filtering,
options, hooks, or control mode. The end-to-end spec requires tmux to be installed.
