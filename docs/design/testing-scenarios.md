# Testing::Scenario design

## Purpose

A named scenario is a reusable description of an interactive REPL test. It should
make the sequence of user-visible actions clear without repeating the mechanics
of Tmux session management, event collection, assertions, cleanup, or reporting.

The existing block-based `Testing.run("name") { |test| ... }` API remains useful
for one-off tests. `Testing::Scenario` is the declarative API for reusable
scenarios and the repository's standard smoke tests.

## Decisions

### A scenario is the execution context

`Testing::Scenario` inherits from `Testing`. A scenario instance therefore
owns the same runtime state and exposes the same helpers as the block-based
runner. Step bodies execute with that instance as `self`, so they can call
`start_cli`, `submit`, `press`, and expectation methods directly.

This deliberately avoids trying to rebind the receiver of a stored block.
Crystal blocks retain the receiver from the context in which they are created;
the class-level `step` macro expands the body into an instance method instead.

### Declarations are class-level; execution state is per instance

`step "name" do ... end` declares one step on the scenario class. It must not
store mutable execution state on the class. Each invocation of
`Testing.run(MyScenario, ...)` constructs a new scenario instance, and that
instance owns its Tmux resources, current stage, sequence, and report. An
`inherited` hook preserves the generated method chain for further subclasses.

### Declaration order is execution order

Each `step` declaration contributes a `run_steps` method that invokes the
previous definition before recording and executing its own body. This method
chain preserves source declaration order and naturally includes steps declared
by ancestor scenario classes before steps declared by subclasses. There is no
shared mutable class-level step registry.

A failure is recorded by the runner and propagated. Later steps do not run.
The runner remains the sole owner of timing, PASS/FAIL records, delays, final
cleanup, client restoration, and JSON reporting.

### Keep one execution engine

The scenario DSL only describes and orders steps. It does not introduce a
second runner or duplicate lifecycle logic. Both the declarative and block-based
APIs use the same `Testing#run` lifecycle and `record_step` implementation.

## Contract to test

- Steps execute exactly once and in source declaration order.
- Parent scenario steps precede child scenario steps.
- Separate scenario instances do not share mutable state.
- A failing step is reported and stops the remaining steps.
- Block-based testing continues to use the same runner behavior.
