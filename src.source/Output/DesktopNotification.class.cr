getter notify_send_path : String

def initialize(@notify_send_path : String = ENV["TMUX_REPL_NOTIFY_SEND"]? || "notify-send")
end

# Display a short confirmation outside the tmux pane. Notification delivery
# is optional and must never affect a successful clipboard operation.
def output_copied : Bool
  status = Process.run(
    @notify_send_path,
    [
      "--app-name=tmux.repl",
      "--urgency=low",
      "--expire-time=1500",
      "Output copied",
      "Available in X11 CLIPBOARD and PRIMARY.",
    ],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close
  )
  status.success?
rescue
  false
end
