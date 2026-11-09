# tmux-repl

A reusable two-pane Tmux REPL library and command-line tools, implemented in Crystal.

The tmux.repl executable orchestrates a named Tmux session. The left and right
panes run separate frontends. Standard REPLs use a background PTY worker for
shell commands; custom-command REPLs dispatch registered handlers in the
application process that owns their state. The companion executables are
independent processes so reply and crystal.pty are never imported by the same executable.

## Executable roles

- tmux.repl creates, activates, and stops a named Tmux session.
- tmux.repl.input reads and publishes commands in the left pane.
- tmux.repl.output renders the selected input and its associated output.
- tmux.repl.worker executes commands through PTY::Session and publishes output.
- tmux.repl.custom_repl is an executable example of an application-owned custom REPL.

Build the executables with:

    shards build

By default, the CLI prefers the companion executables beside the running
tmux.repl binary, then searches the invoking process's $PATH. Each companion
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

Start a REPL session with `tmux.repl start [SESSION] [--no-focus]`; stop it with
tmux.repl stop [SESSION].

When the left pane is active, submit shell commands as usual. Each input gets an
ID. Use these controls in the left pane to select which input is shown on the right:

    :list       List submitted inputs
    :select ID  Display the output associated with a specific input
    :prev       Select the previous input
    :next       Select the next input
    Ctrl+Up     Select the previous input (primary)
    Ctrl+Down   Select the next input (primary)
    Alt+K       Select the previous input (alias)
    Alt+J       Select the next input (alias)
    :help       Show these controls

Alt+K/J are handled only when tmux passes the chords through to the input pane.
The ch1c0t/tmux.pane_movements executables forward them automatically when the
foreground command is tmux.repl.input; custom bindings must do the same.

Scroll the displayed output from either pane with Alt+Up/Alt+Down (one line) or
Alt+PageUp/Alt+PageDown (one page). In the output pane, the unmodified Up/Down
and PageUp/PageDown keys work as well. The command header and exit status remain
visible while navigating. The output footer reports the visible logical-line
range and total, marking the total as provisional while a command is streaming.
Long output lines wrap by default; Ctrl+W switches to NO-WRAP so each logical
line stays on one row. In NO-WRAP mode, Left/Right scroll horizontally and
Home/End jump to either edge in the output pane. Use Alt+Left/Alt+Right and
Alt+Home/Alt+End for the same actions from the input pane. Press Alt+Z in
either pane to zoom the Output pane to fill the Tmux window; press Alt+Z again
to restore the split and return focus to whichever pane was active when zooming in was requested. Press Ctrl+G in either pane to toggle between stripped
and raw transcript views.
Press Ctrl+L in either pane to toggle the available-outputs list. It shows each
submitted input, its running/exit state, output-line count and first-line preview.
Use the existing scroll keys to browse the list, then Ctrl+L to return to the output.

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

## Custom-command REPLs

Use `on_command` when commands need access to objects owned by the application
process, rather than a shell or a separate PTY worker. Handlers receive a
`CustomREPL::CommandContext` for streamed output and an array of parsed arguments:

    repl = TmuxREPL.define("vm") do |definition|
      definition.on_command("ocr") do |context, arguments|
        context.puts(vm.latest_ocr)
      end

      definition.on_command("key") do |context, arguments|
        action, key = arguments
        vm.send_key(action, key)
        context.puts("Sent #{action} #{key}")
      end
    end

    repl.start
    repl.serve

`start` subscribes the application process to the session's command stream
before exposing the input pane. Custom sessions use the regular input/output
frontends but do not start `tmux.repl.worker`. Call `serve` from the process
that owns the handlers; it blocks until the Tmux session is closed. This lets a
handler use an existing VM, browser, database connection, or other in-process
application state without serializing it into a worker.

The handler receives the command's arguments as strings. Single and double
quotes group arguments, and backslashes escape characters outside single
quotes. Custom commands are not passed to a shell and are never shell-evaluated.
Use `context.write(chunk)` to stream output as it becomes available, or
`context.puts(text)` to publish a line. Unknown commands complete with exit
status 127; handler exceptions are displayed in the output pane with exit
status 1.

The `tmux.repl.custom_repl` target is a small executable custom-REPL
application used as the process-boundary fixture. It defines its handlers,
starts the session, and blocks in `serve` in its own process. Real applications
follow the same pattern while closing over their own VM, browser, database
connection, or other in-process state.

Run the fixture with:

    tmux.repl.custom_repl start SESSION [--no-focus]

## Testing REPLs

`TmuxREPL::Testing` provides a scenario runner for interactive and custom REPL
tests. It owns Tmux session discovery, pane access, key injection, bounded
waits, cleanup, client restoration, and a common JSON report. A
`Testing::Scenario` subclass declares named steps with the class-level `step`
macro. The steps execute in declaration order on the scenario instance, which
inherits the runner's public testing helpers. Each step is timed and reported
by the same runner used by the block-based API.

    require "tmux_repl"

    class MyCustomREPLScenario < TmuxREPL::Testing::Scenario
      step "start the custom REPL" do
        session_name = "my-custom-repl-#{Process.pid}"
        start_host(
          "./bin/my-custom-repl",
          ["start", session_name],
          session_name
        )
      end

      step "execute the OCR command" do
        submit("ocr").expect_output("SCREEN OCR:").expect_status(0)
      end
    end

    TmuxREPL::Testing.run(
      MyCustomREPLScenario,
      name: "my-custom-repl",
      cleanup: :always
    )

`start_cli("./bin/tmux.repl", ["start"])` exercises the standard CLI.
`start_host(executable, arguments, session_name)` launches a long-running
custom application as a child process, waits for that exact Tmux session and
both frontend readiness markers, and captures its output in a host log.
`start_custom(definition)` remains available for faster in-process tests.
The custom smoke test uses `start_host`, so command handlers are owned by a
separate application process rather than the test runner. Custom test sessions
must always be cleaned up; standard REPL sessions can be left open for
inspection. The block-based `Testing.run("name") { |test| ... }` API remains
available for ad-hoc tests that do not need a reusable scenario class.

When the runner is configured with `focus=0`, it passes `--no-focus` to the
CLI instead of exporting a test-only environment variable into the application
process. The standard and custom fixture CLIs both support this option.

The scenario's execution policy is read from environment variables. A
scenario-specific variable takes precedence over its shared counterpart.
For example, the custom scenario uses `TMUX_REPL_TEST_CUSTOM_REPL_FOCUS`, then
falls back to `TMUX_REPL_TEST_FOCUS`.

| Variable | Values | Default |
|---|---|---|
| `TMUX_REPL_TEST_FOCUS` | `1` / `0` | `1` |
| `TMUX_REPL_TEST_RESTORE_CLIENT` | `1` / `0` | `1` |
| `TMUX_REPL_TEST_CLEANUP` | `always`, `never`, `on_failure` | Scenario default |
| `TMUX_REPL_TEST_DELAY` | Seconds between successful steps | Scenario default |
| `TMUX_REPL_TEST_TIMEOUT` | Seconds for command and UI assertions | `8` |
| `TMUX_REPL_TEST_START_TIMEOUT` | Seconds to discover a started session | `8` |
| `TMUX_REPL_TEST_HOST_STOP_TIMEOUT` | Seconds to wait for a custom host | `5` |

To configure one scenario without affecting others, insert its name after
`TMUX_REPL_TEST_`. For example:

    TMUX_REPL_TEST_CUSTOM_REPL_FOCUS=0
    TMUX_REPL_TEST_CUSTOM_REPL_TIMEOUT=15
    TMUX_REPL_TEST_TMUX_REPL_CLEANUP=on_failure

Boolean values accept `1/0`, `true/false`, `yes/no`, and `on/off`.
Durations are non-negative seconds. Invalid values fail the test at startup
instead of silently falling back.

`focus=0` starts the session without switching the current Tmux client.
`restore_client=0` leaves the client where the scenario left it. Cleaning up
a focused session requires client restoration. `cleanup=on_failure` removes a
standard REPL session only when the scenario fails; on success it is left open.
Use `cleanup=always` to remove it in either case, or `never` to always retain
it. Custom REPL scenarios require `cleanup=always`: the runner owns the host
lifecycle and must stop the child process before it exits.

`submit` returns a command result. Output and completion expectations are
correlated with the sequence-numbered LavinMQ event stream, then checked against
the Output pane. Use `press(:input, "C-Up")`,
`press(:output, "PageDown")`, `expect_selected_input(1)`,
`expect_visible(...)`, and `expect_zoomed(true)` for presentation checks.
The delay is only an optional observation pause; it is not used for
synchronization.

Both smoke-test executables write the same versioned JSON report under
`$XDG_STATE_HOME/tmux.repl/smoke-tests` (or
`$HOME/.local/state/tmux.repl/smoke-tests` when `XDG_STATE_HOME` is unset).
The report records the effective configuration as well as each step's result
and duration.

## Session state

Session state is stored under `$XDG_STATE_HOME/tmux.repl`, or
`$HOME/.local/state/tmux.repl` when `XDG_STATE_HOME` is unset. Each Tmux
session gets a collision-resistant directory under `sessions/`:

    sessions/<safe-session-name>-<name-hash>/
      session.yml
      input.pid, input.startup, input.error
      output.pid, output.startup, output.error
      worker.pid, worker.startup, worker.error
      logs/
        keyboard.trace.log
        timing.log

The YAML manifest records the exact `session_name` and absolute `base_path`,
so companion processes can resolve the original Tmux name and session directory
without reconstructing either from a filesystem-safe slug. Stopping a session
removes transient PID/startup files and captured output, but preserves its
manifest, startup-error details, and diagnostic logs.

The interactive smoke-test report is stored separately under
`$XDG_STATE_HOME/tmux.repl/smoke-tests` (or the corresponding default state
directory when XDG_STATE_HOME is unset).

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

### Interactive smoke test

Build with `shards build`, then run `./bin/tmux.repl.test` from inside the
Tmux session you want to return to. The smoke test runs `./bin/tmux.repl start`,
submits sample commands, and checks command selection, RAW/STRIPPED toggling,
the available-outputs list, and scrolling from both panes. The test session is
shown while the checks run, then left open; the client switches back to the
original session to display the report.

Set `TMUX_REPL_TEST_DELAY` to adjust the pause after each check
(seconds, default `0.8`). The other `TMUX_REPL_TEST_*` variables described
above control focus, client restoration, cleanup, and timeouts.

### Tracing command latency

Start a new session with timing diagnostics enabled:

    TMUX_REPL_TRACE_TIMING=1 tmux.repl start latency-debug

Run a few commands, including the first one, then inspect the session's `logs/timing.log` file. Its location is recorded in
`session.yml` under the corresponding `sessions/<safe-session-name>-<name-hash>/`
directory.
The trace separates input publication, worker delivery, PTY execution, output-event publication, and output-pane rendering.
Tracing is disabled by default.
