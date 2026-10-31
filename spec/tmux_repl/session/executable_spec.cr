require "./helper"

describe TmuxREPL::Session::CompanionExecutable do
  it "prefers an executable beside the invoking tmux.repl binary by default" do
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
      nil,
      path_directory
    ).should eq(companion_path)
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "prefers an explicit executable override over sibling and PATH copies" do
    directory = File.join(Dir.tempdir, "tmux-repl-override-#{Process.pid}")
    bin_directory = File.join(directory, "bin")
    path_directory = File.join(directory, "path")
    override_directory = File.join(directory, "override")
    [bin_directory, path_directory, override_directory].each { |path| FileUtils.mkdir_p(path) }

    program_path = File.join(bin_directory, "tmux.repl")
    sibling_path = File.join(bin_directory, "tmux.repl.input")
    path_copy = File.join(path_directory, "tmux.repl.input")
    override_path = File.join(override_directory, "tmux.repl.input")
    [sibling_path, path_copy, override_path].each do |path|
      File.write(path, "#!/bin/sh\nexit 0\n")
      File.chmod(path, 0o755)
    end

    TmuxREPL::Session::CompanionExecutable.resolve(
      "tmux.repl.input",
      program_path,
      override_path,
      path_directory
    ).should eq(override_path)
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "resolves an override command name through PATH" do
    directory = File.join(Dir.tempdir, "tmux-repl-override-path-#{Process.pid}")
    FileUtils.mkdir_p(directory)
    override_path = File.join(directory, "custom-input")
    File.write(override_path, "#!/bin/sh\nexit 0\n")
    File.chmod(override_path, 0o755)

    TmuxREPL::Session::CompanionExecutable.resolve(
      "tmux.repl.input",
      File.join(directory, "app", "tmux.repl"),
      "custom-input",
      directory
    ).should eq(override_path)
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "fails clearly when an override is not executable" do
    directory = File.join(Dir.tempdir, "tmux-repl-invalid-override-#{Process.pid}")
    FileUtils.mkdir_p(directory)
    invalid_path = File.join(directory, "not-executable")
    File.write(invalid_path, "not executable")

    error = expect_raises(Exception) do
      TmuxREPL::Session::CompanionExecutable.resolve(
        "tmux.repl.input",
        File.join(directory, "tmux.repl"),
        invalid_path,
        nil
      )
    end
    error.message.to_s.should contain("Configured executable override")
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
      nil,
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
        nil,
        nil
      )
    end
    error.message.to_s.should contain("Cannot find executable")
  end
end
