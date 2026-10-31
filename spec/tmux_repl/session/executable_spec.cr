require "./helper"

describe TmuxREPL::Session::CompanionExecutable do
  it "prefers an executable beside the invoking tmux.repl binary" do
    directory = File.join(Dir.tempdir, "tmux-repl-companions-#{Process.pid}")
    bin_directory = File.join(directory, "bin")
    FileUtils.mkdir_p(bin_directory)

    program_path = File.join(bin_directory, "tmux.repl")
    companion_path = File.join(bin_directory, "tmux.repl.input")
    File.write(companion_path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, companion_path)

    TmuxREPL::Session::CompanionExecutable.resolve(
      "tmux.repl.input",
      program_path
    ).should eq(companion_path)
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "falls back to PATH lookup when there is no executable sibling" do
    program_path = File.join(Dir.tempdir, "tmux-repl-without-companions-#{Process.pid}", "tmux.repl")

    TmuxREPL::Session::CompanionExecutable.resolve(
      "tmux.repl.input",
      program_path
    ).should eq("tmux.repl.input")
  end
end
