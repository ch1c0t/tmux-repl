require "./tmux.repl.test/*"

VERSION = "0.1.0"

case ARGV.size
when 1
  case ARGV[0]
  when "-v", "version", "--version"
    puts VERSION
    exit
  when "-h", "help", "--help"
    print_help
    exit
  end
end

require "../tmux_repl"

class StandardREPLScenario < TmuxREPL::Testing::Scenario
  step "Run ./bin/tmux.repl start" do
    start_cli("./bin/tmux.repl", ["start"])
  end

  step "Find the new session and its two panes" do
    expect_visible("No inputs yet.", timeout: 3.seconds)
  end

  step "Submit the first command" do
    submit(%(printf 'SMOKE_FIRST_OUTPUT\\n')).expect_output("SMOKE_FIRST_OUTPUT").expect_status(0)
  end

  step "Submit the second command" do
    submit(%(printf 'SMOKE_SECOND_OUTPUT\\n')).expect_output("SMOKE_SECOND_OUTPUT").expect_status(0)
  end

  step "Ctrl+Up selects the previous output" do
    press(:input, "C-Up")
    expect_selected_input(1)
    expect_visible("SMOKE_FIRST_OUTPUT")
  end

  step "Ctrl+Down selects the next output" do
    press(:input, "C-Down")
    expect_selected_input(2)
    expect_visible("SMOKE_SECOND_OUTPUT")
  end

  step "Alt+K selects the previous output" do
    press(:input, "M-k")
    expect_selected_input(1)
    expect_visible("SMOKE_FIRST_OUTPUT")
  end

  step "Alt+J selects the next output" do
    press(:input, "M-j")
    expect_selected_input(2)
    expect_visible("SMOKE_SECOND_OUTPUT")
  end

  step "Ctrl+L opens the available-outputs list from the input pane" do
    press(:input, "C-l")
    expect_visible("AVAILABLE OUTPUTS (2)", "#1", "#2")
  end

  step "Ctrl+L closes the list from the output pane" do
    press(:output, "C-l")
    expect_visible("INPUT #2", "SMOKE_SECOND_OUTPUT")
  end

  step "Submit a command for raw/stripped view testing" do
    command = %(for i in $(seq 1 4); do printf 'SMOKE_STREAM_TICK_%s\\n' "$i" && sleep 0.15; done)
    submit(command).expect_output("SMOKE_STREAM_TICK_4").expect_status(0)
  end

  step "Ctrl+G from the input pane switches to raw output" do
    press(:input, "C-g")
    expect_visible("[RAW;", "START_MARK_", "END_MARK_")
  end

  step "Ctrl+G from the output pane switches back to stripped output" do
    press(:output, "C-g")
    expect_visible("[STRIPPED;", "SMOKE_STREAM_TICK_4")
    expect_output_without("START_MARK_")
    expect_output_without("END_MARK_")
  end

  step "Submit a command with enough lines to scroll" do
    command = %(for i in $(seq 1 60); do printf 'SMOKE_SCROLL_LINE_%02d\\n' "$i"; done)
    submit(command).expect_output("SMOKE_SCROLL_LINE_60").expect_status(0)
  end

  step "PageUp in the output pane reaches the first lines" do
    4.times { press(:output, "PageUp") }
    expect_visible("SMOKE_SCROLL_LINE_01")
    expect_output_without("SMOKE_SCROLL_LINE_60")
  end

  step "Down in the output pane scrolls by one line" do
    press(:output, "Down")
    expect_visible("SMOKE_SCROLL_LINE_02")
  end

  step "Up in the output pane scrolls back by one line" do
    press(:output, "Up")
    expect_visible("SMOKE_SCROLL_LINE_01")
  end

  step "PageDown in the output pane returns to the latest lines" do
    4.times { press(:output, "PageDown") }
    expect_visible("SMOKE_SCROLL_LINE_60")
  end

  step "Alt+PageUp in the input pane reaches the first lines" do
    4.times { press(:input, "M-PageUp") }
    expect_visible("SMOKE_SCROLL_LINE_01")
    expect_output_without("SMOKE_SCROLL_LINE_60")
  end

  step "Alt+Down in the input pane scrolls by one line" do
    press(:input, "M-Down")
    expect_visible("SMOKE_SCROLL_LINE_02")
  end

  step "Alt+Up in the input pane scrolls back by one line" do
    press(:input, "M-Up")
    expect_visible("SMOKE_SCROLL_LINE_01")
  end

  step "Alt+PageDown in the input pane returns to the latest lines" do
    4.times { press(:input, "M-PageDown") }
    expect_visible("SMOKE_SCROLL_LINE_60")
  end

  step "Alt+Z from Input zooms Output" do
    select_pane(:input)
    press(:input, "M-z")
    expect_zoomed(true)
    expect_active_pane(:output)
  end

  step "Alt+Z from Output restores the split and Input focus" do
    press(:output, "M-z")
    expect_zoomed(false)
    expect_active_pane(:input)
  end

  step "Alt+Z from Output zooms Output" do
    select_pane(:output)
    press(:output, "M-z")
    expect_zoomed(true)
    expect_active_pane(:output)
  end

  step "Alt+Z from Output restores the split and Output focus" do
    press(:output, "M-z")
    expect_zoomed(false)
    expect_active_pane(:output)
  end

  step "Leave the smoke-test session running" do
    raise "The smoke-test Tmux session disappeared." unless session_exists?(session_name)
  end
end

begin
  TmuxREPL::Testing.run(
    StandardREPLScenario,
    name: "tmux.repl",
    cleanup: :never,
    focus: true,
    restore_client: true,
    step_delay: 0.8.seconds
  )
rescue ex
  STDERR.puts "tmux.repl smoke test: #{ex.class}: #{ex.message}"
  exit 1
end
