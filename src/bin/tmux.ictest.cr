require "./tmux.ictest/*"

VERSION = "0.1.0"

case ARGV.size
when 1
  case ARGV[0]
  when "-v", "version", "--version"
    puts VERSION
    exit
  when "-h", "help", "--help"
    print_help
    exit
  end
end

require "time"
require "../tmux"

module TmuxICTest
  def self.bootstrap
    unless ENV["TMUX"]? && ENV["TMUX_PANE"]?
      STDERR.puts "tmux.ictest must be run inside a tmux pane."
      exit 2
    end

    executable = Process.executable_path || File.expand_path(PROGRAM_NAME)
    directory = File.dirname(executable)
    source_candidates = [
      File.expand_path(File.join(directory, "tmux.ictest.cr")),
      File.expand_path(File.join(directory, "../src/bin/tmux.ictest.cr")),
      File.expand_path(File.join(directory, "../src.source/bin/tmux.ictest.cr")),
      File.expand_path(__FILE__),
      File.expand_path("src/bin/tmux.ictest.cr"),
      File.expand_path("src.source/bin/tmux.ictest.cr"),
    ]
    source = source_candidates.find { |path| File.file?(path) }
    unless source
      STDERR.puts "Cannot locate tmux.ictest.cr; keep the source beside tmux.ictest or run from the repository."
      exit 2
    end

    ENV["TMUX_ICTEST_INTERPRETED"] = "1"
    Process.exec(ENV["IC_EXECUTABLE"]? || "ic", [source])
  end
end

TmuxICTest.bootstrap unless ENV["TMUX_ICTEST_INTERPRETED"]? == "1"
ENV.delete("TMUX_ICTEST_INTERPRETED")

ictest_started_at = Time.local
ictest_process_id = Process.pid
ictest_server = Tmux::Server.from_env
ictest_pane = Tmux::Pane.from_env
ictest_window = ictest_pane.window
ictest_session = ictest_pane.session
ictest_environment = ENV.to_h

def ocr
  puts "from #ocr"
end

puts "tmux.ictest is ready; inspect ictest_* locals in IC Pry."
debugger
