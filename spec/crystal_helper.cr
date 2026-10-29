require "spec"
require "time"
require "../src/tmux"

# Poll a condition until it succeeds or the timeout expires.
def wait_until(
  timeout : Time::Span = 3.seconds,
  interval : Time::Span = 25.milliseconds,
  &condition : -> Bool
) : Bool
  deadline = Time.instant + timeout

  while Time.instant < deadline
    return true if yield
    sleep interval
  end

  yield
end

def wait_for_file(path : String, timeout : Time::Span = 5.seconds) : Bool
  wait_until(timeout, 10.milliseconds) { File.exists?(path) }
end

def pane_text(pane : Tmux::Pane) : String
  pane.capture_pane.join("\n")
end

def pane_shows?(
  pane : Tmux::Pane,
  expected : Array(String),
  timeout : Time::Span = 3.seconds,
  interval : Time::Span = 25.milliseconds
) : Bool
  wait_until(timeout, interval) do
    visible = pane_text(pane)
    expected.all? { |text| visible.includes?(text) }
  end
end

def stop_tmux_server(server : Tmux::Server) : Nil
  server.kill_server
rescue Tmux::Error
end

def with_environment(name : String, value : String?, &block : -> T) : T forall T
  previous_value = ENV[name]?
  ENV[name] = value
  yield
ensure
  ENV[name] = previous_value
end
