require "./helper"

describe TmuxREPL::Session::CompanionExecutable do
  it "prefers an executable beside the invoking tmux.repl binary" do
    directory = File.join(Dir.tempdir, "tmux-repl-companions-#{Process.pid}")
    bin_directory = File.join(directory, "bin")
    path_directory = File.join(directory, "path")
    FileUtils.mkdir_p(bin_directory)
    FileUtils.mkdir_p(path_directory)

    program_path = File.join(bin_directory, "tmux.repl")
    companion_path = File.join(bin_directory, "tmux.repl.input")
    shadow_path = File.join(path_directory, "tmux.repl.input")
    [companion_path, shadow_path].each do |path|
      File.write(path, "#!/bin/sh\nexit 0\n")
      File.chmod(path, 0o755)
    end

    TmuxREPL::Session::CompanionExecutable.resolve(
      "tmux.repl.input",
      program_path,
      path_directory
    ).should eq(companion_path)
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "resolves a PATH executable to an absolute path when no sibling exists" do
    directory = File.join(Dir.tempdir, "tmux-repl-path-companions-#{Process.pid}")
    path_directory = File.join(directory, "path")
    FileUtils.mkdir_p(path_directory)

    companion_path = File.join(path_directory, "tmux.repl.input")
    File.write(companion_path, "#!/bin/sh\nexit 0\n")
    File.chmod(companion_path, 0o755)

    TmuxREPL::Session::CompanionExecutable.resolve(
      "tmux.repl.input",
      File.join(directory, "app", "tmux.repl"),
      path_directory
    ).should eq(companion_path)
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "fails clearly when the companion is neither a sibling nor on PATH" do
    error = expect_raises(Exception) do
      TmuxREPL::Session::CompanionExecutable.resolve(
        "tmux.repl.input",
        File.join(Dir.tempdir, "tmux-repl-missing-#{Process.pid}", "tmux.repl"),
        nil
      )
    end
    error.message.to_s.should contain("Cannot find executable")
  end
end
