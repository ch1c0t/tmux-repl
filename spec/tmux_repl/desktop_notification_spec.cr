require "../../src/output"

describe Output::DesktopNotification do
  it "sends a short desktop notification without writing to the tmux pane" do
    directory = File.join(Dir.tempdir, "tmux-repl-notification-#{Process.pid}")
    FileUtils.mkdir_p(directory)

    executable = File.join(directory, "notify-send")
    arguments_path = File.join(directory, "arguments")
    script = <<-SH
      #!/usr/bin/env sh
      set -eu
      printf '%s\n' "$@" > "#{arguments_path}"
    SH
    File.write(executable, script)
    File.chmod(executable, 0o755)

    Output::DesktopNotification.new(executable).output_copied.should be_true
    File.read(arguments_path).lines.map(&.chomp).should eq([
      "--app-name=tmux.repl",
      "--urgency=low",
      "--expire-time=1500",
      "Output copied",
      "Available in X11 CLIPBOARD and PRIMARY.",
    ])
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "treats an unavailable notification command as optional" do
    missing_command = File.join(Dir.tempdir, "tmux-repl-notify-send-missing-#{Process.pid}")
    Output::DesktopNotification.new(missing_command).output_copied.should be_false
  end

  it "returns false when the notification command exits unsuccessfully" do
    directory = File.join(Dir.tempdir, "tmux-repl-notification-failure-#{Process.pid}")
    FileUtils.mkdir_p(directory)

    executable = File.join(directory, "notify-send")
    File.write(executable, "#!/usr/bin/env sh\nexit 1\n")
    File.chmod(executable, 0o755)

    Output::DesktopNotification.new(executable).output_copied.should be_false
  ensure
    FileUtils.rm_rf(directory) if directory
  end
end
