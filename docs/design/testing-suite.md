# Testing::Suite design

## Purpose

`Testing::Suite` composes reusable `Testing::Scenario` classes into one
ordered run. It is an orchestration layer, not another implementation of the
interactive test lifecycle.

## Decisions

### Explicit registration

Call `Suite#add` with a scenario class, a unique scenario name, and that
scenario's `Testing::Configuration` options. The suite does not discover
subclasses automatically. Explicit registration makes membership and execution
order visible in source code and avoids relying on runtime class discovery.

### One scenario execution engine

Each registration delegates to `Testing.run_result`, which constructs a fresh
scenario instance and uses the existing `Testing#run_result` lifecycle. The
block-based `Testing.run` API and the class-based `Testing.run` API retain
their exception-raising behavior; the result-returning path exists so a suite
can collect failures without aborting its own orchestration.

The suite does not implement Tmux control, step execution, assertions, cleanup,
or individual scenario reporting.

### Sequential execution

Scenarios run sequentially in registration order. They share a Tmux server,
client, and LavinMQ service, so parallel execution would complicate focus,
cleanup, and diagnosis. Parallel scheduling is intentionally outside this
initial API.

### Failure policy

The default is to record a failed scenario and continue to the next one. With
`fail_fast: true`, the first failure stops execution and later registrations
are recorded as skipped. A failure to initialize a scenario is recorded in the
aggregate report even when no individual scenario report could be created.

### Reporting

Every executed scenario keeps its individual JSON report. The suite writes a
second JSON report containing each scenario's status, duration, individual
report path when available, and failure details. `Suite#run` returns a report
whose `success?` and `exit_code` describe the overall outcome.

## Public shape

```crystal
suite = TmuxREPL::Testing::Suite.new("integration")
suite.add(StandardREPLScenario, name: "standard", cleanup: :never)
suite.add(CustomREPLScenario, name: "custom", cleanup: :always)

report = suite.run
exit report.exit_code
```
