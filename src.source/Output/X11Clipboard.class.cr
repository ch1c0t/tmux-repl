getter xclip_path : String

def initialize(@xclip_path : String = ENV["TMUX_REPL_XCLIP"]? || "xclip")
end

# Copy the same complete text to both X11 selections, matching Neovim's + and * registers.
def copy(text : String) : Nil
  {"clipboard", "primary"}.each do |selection|
    status = Process.run(
      @xclip_path,
      ["-selection", selection, "-i"],
      input: IO::Memory.new(text),
      output: Process::Redirect::Close
    )

    unless status.success?
      raise "xclip exited with status #{status.exit_code} for the #{selection} selection"
    end
  end
end
