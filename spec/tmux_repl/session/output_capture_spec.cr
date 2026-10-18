require "./helper"

describe TmuxREPL::Session do
  it "captures output from an interactive REPL command" do
    name = "repl_spec_#{Process.pid}"
    state_home = File.join(ENV["TMPDIR"]? || "/tmp", "tmux-repl-e2e-#{Process.pid}")
    log = File.join(state_home, "tmux-repl", name, "output.log")
    previous_state_home = ENV["XDG_STATE_HOME"]?
    ENV["XDG_STATE_HOME"] = state_home
    session = TmuxREPL::Session.new(name, command: [
      "sh", "-c", "printf '%s%s' 'TMUX_REPL_' 'LIBRARY_E2E'; sleep 1"
    ])
    found = false

    begin
      session.start(focus: false)
      deadline = Time.instant + 5.seconds
      while Time.instant < deadline
        if File.exists?(log) && File.read(log).includes?("TMUX_REPL_LIBRARY_E2E")
          found = true
          break
        end
        sleep 50.milliseconds
      end
      found.should be_true
    ensure
      session.stop
      ENV["XDG_STATE_HOME"] = previous_state_home
      FileUtils.rm_rf(state_home)
    end
  end
end
