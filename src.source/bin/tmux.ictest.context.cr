require "time"
require "../tmux"

ictest_started_at = Time.local
ictest_process_id = Process.pid
ictest_server = Tmux::Server.from_env
ictest_pane = Tmux::Pane.from_env
ictest_window = ictest_pane.window
ictest_session = ictest_pane.session
ictest_parent_pane_id = ENV["TMUX_ICTEST_PARENT_PANE"]?
ictest_parent_pane = if parent_pane_id = ictest_parent_pane_id
  ictest_server.panes.find { |candidate| candidate.pane_id == parent_pane_id }
end
ictest_environment = ENV.to_h

def ocr
  puts "from #ocr"
end

puts "tmux.ictest is ready; continue at the debugger prompt to return to the pane shell."
debugger
debugger
