module LavinMQProcess
  class Scenario
    getter name : String

    @state_home : String
    @worker_pid_path : String
    @ready_paths : Array(String)
    @previous_environment : Hash(String, String?)
    @server : Tmux::Server
    @repl : TmuxREPL::Session
    @stage = "initialization"
    @bootstrap_started = false
    @repl_started = false
    @tmux_session : Tmux::Session?
    @input_pane : Tmux::Pane?
    @output_pane : Tmux::Pane?

    def initialize
      @name = "repl_lavinmq_spec_#{Process.pid}"
      @state_home = File.join(ENV["TMPDIR"]? || "/tmp", "tmux-repl-lavinmq-#{Process.pid}")
      @worker_pid_path = ""
      @ready_paths = [] of String

      @previous_environment = {
        "XDG_STATE_HOME" => ENV["XDG_STATE_HOME"]?,
        "PATH"           => ENV["PATH"]?,
        "TMUX"           => ENV["TMUX"]?,
        "LOG_LEVEL"       => ENV["LOG_LEVEL"]?,
      }
      @server = Tmux::Server.new(socket_path: File.join(@state_home, "tmux.sock"))
      @repl = TmuxREPL::Session.new(@name)
    end

    def run : Nil
      begin
        @stage = "startup"
        start

        @stage = "input history and command selection"
        verify_selection

        @stage = "streaming, completion, and Ctrl+G view toggling"
        verify_streaming_and_toggle

        @stage = "worker shutdown"
        stop_worker
      ensure
        @stage = "cleanup"
        cleanup
      end
    end

    private def input_pane : Tmux::Pane
      @input_pane.not_nil!
    end

    private def output_pane : Tmux::Pane
      @output_pane.not_nil!
    end

    private def tmux_session : Tmux::Session
      @tmux_session.not_nil!
    end

    include Diagnostics
    include Setup
    include Selection
    include Streaming
    include Shutdown
  end
end
