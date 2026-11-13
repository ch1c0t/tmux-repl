require "../../src/output"

describe Output::X11Clipboard do
  it "copies the same text to both the CLIPBOARD and PRIMARY selections" do
    directory = File.join(Dir.tempdir, "tmux-repl-x11-clipboard-#{Process.pid}")
    FileUtils.mkdir_p(directory)

    executable = File.join(directory, "xclip")
    selections_path = File.join(directory, "selections")
    script = <<-SH
      #!/usr/bin/env sh
      set -eu
      printf '%s\n' "$2" >> "#{selections_path}"
      cat > "#{directory}/$2"
    SH
    File.write(executable, script)
    File.chmod(executable, 0o755)

    text = "first line\nsecond line\n"
    Output::X11Clipboard.new(executable).copy(text)

    File.read(selections_path).lines.map(&.strip).should eq(["clipboard", "primary"])
    File.read(File.join(directory, "clipboard")).should eq(text)
    File.read(File.join(directory, "primary")).should eq(text)
  ensure
    FileUtils.rm_rf(directory) if directory
  end
end
