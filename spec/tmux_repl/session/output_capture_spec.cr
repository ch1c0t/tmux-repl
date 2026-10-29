require "./helper"

describe TmuxREPL::Session do
  it "captures output from an interactive REPL command" do
    name = "repl_spec_#{Process.pid}"
    state_home = File.join(ENV["TMPDIR"]? || "/tmp", "tmux-repl-e2e-#{Process.pid}")
    log_path = File.join(state_home, "tmux-repl", name, "output.log")
    previous_state_home = ENV["XDG_STATE_HOME"]?
    session = TmuxREPL::Session.new(
      name,
      command: ["sh", "-c", "printf '%s%s' 'TMUX_REPL_' 'LIBRARY_E2E'; sleep 1"]
    )

    begin
      ENV["XDG_STATE_HOME"] = state_home
      session.start(focus: false)

      wait_until(5.seconds, 50.milliseconds) do
        File.exists?(log_path) && File.read(log_path).includes?("TMUX_REPL_LIBRARY_E2E")
      end.should be_true
    ensure
      session.stop
      ENV["XDG_STATE_HOME"] = previous_state_home
      FileUtils.rm_rf(state_home)
    end
  end
end
