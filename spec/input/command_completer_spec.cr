require "file_utils"
require "../../src/input"

describe Input::CommandCompleter do
  it "suggests executable commands from PATH by prefix" do
    directory = File.join(Dir.tempdir, "tmux-repl-completion-#{Process.pid}-#{Time.utc.to_unix_ms}")
    FileUtils.mkdir_p(directory)

    begin
      command_path = File.join(directory, "prepare_alpine_bundle")
      File.write(command_path, "#!/bin/sh\n")
      File.chmod(command_path, 0o755)

      completer = Input::CommandCompleter.new(directory)

      completer.complete("prepare_alpine").should eq(["prepare_alpine_bundle"])
      completer.complete("prepare_").should eq(["prepare_alpine_bundle"])
      completer.complete("missing").should be_empty
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "does not suggest non-executable files" do
    directory = File.join(Dir.tempdir, "tmux-repl-completion-#{Process.pid}-#{Time.utc.to_unix_ms}")
    FileUtils.mkdir_p(directory)

    begin
      File.write(File.join(directory, "prepare_alpine_bundle"), "not executable")

      completer = Input::CommandCompleter.new(directory)

      completer.complete("prepare").should be_empty
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "includes common POSIX shell builtins" do
    completer = Input::CommandCompleter.new("")

    completer.complete("pri").should contain("printf")
    completer.complete("ex").should contain("exec")
  end
end
