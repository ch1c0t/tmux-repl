require "../crystal_helper"
require "../../src/tmux_repl"

describe TmuxREPL::State do
  it "writes a YAML manifest with the original session name and absolute base path" do
    directory = File.join(Dir.tempdir, "tmux-repl-state-#{Process.pid}")

    with_environment("XDG_STATE_HOME", directory) do
      with_environment("TMUX_REPL_SESSION_STATE", nil) do
        session_name = "crystal/tmux-repl"
        state = TmuxREPL::State.new(session_name)
        state.prepare

        manifest = YAML.parse(File.read(state.manifest_path))
        manifest["session_name"].as_s.should eq(session_name)
        manifest["base_path"].as_s.should eq(state.base_path)
        state.base_path.should start_with(File.join(directory, "tmux.repl", "sessions"))

        loaded = TmuxREPL::State.read(state.base_path)
        loaded.session_name.should eq(session_name)
        loaded.base_path.should eq(state.base_path)

        opened = TmuxREPL::State.open(session_name)
        opened.session_name.should eq(session_name)
        opened.base_path.should eq(state.base_path)
      end
    end
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "uses distinct directories for names that sanitize to the same slug" do
    first = TmuxREPL::State.new("crystal/tmux-repl")
    second = TmuxREPL::State.new("crystal-tmux-repl")

    first.base_path.should_not eq(second.base_path)
  end

  it "preserves manifests, error details, and logs when runtime files are cleaned" do
    directory = File.join(Dir.tempdir, "tmux-repl-state-cleanup-#{Process.pid}")

    with_environment("XDG_STATE_HOME", directory) do
      state = TmuxREPL::State.new("cleanup-spec")
      state.prepare

      File.write(state.path("input.pid"), "123")
      File.write(state.path("input.startup"), "starting")
      File.write(state.path("input.error"), "startup failed")
      File.write(state.path("output.log"), "captured output")
      timing_log = state.log_path("timing.log")
      File.write(timing_log, "event")

      state.cleanup_runtime

      File.exists?(state.path("input.pid")).should be_false
      File.exists?(state.path("input.startup")).should be_false
      File.exists?(state.path("output.log")).should be_false
      File.exists?(state.manifest_path).should be_true
      File.read(state.path("input.error")).should eq("startup failed")
      File.read(timing_log).should eq("event")
    end
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "uses the explicit session base path supplied to companion processes" do
    directory = File.join(Dir.tempdir, "tmux-repl-state-explicit-#{Process.pid}")

    with_environment("XDG_STATE_HOME", directory) do
      state = TmuxREPL::State.new("explicit-spec")
      state.prepare

      with_environment("TMUX_REPL_SESSION_STATE", state.base_path) do
        opened = TmuxREPL::State.open("explicit-spec")
        opened.base_path.should eq(state.base_path)
      end
    end
  ensure
    FileUtils.rm_rf(directory) if directory
  end
end
