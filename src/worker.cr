require "pty"
require "./tmux_repl"

module Worker
  # Background PTY worker implementation.

  class Runner
    module Command
      private def process_message(data : JSON::Any, events) : Nil
        sequence = data["sequence"].as_i64.to_u64
        command = data["command"].as_s
        received_at = Time.instant
      
        TmuxREPL.trace_timing(
          @session_name, "worker", "command_received",
          details: "sequence=#{sequence} command_bytes=#{command.bytesize}"
        )
      
        publish_started(events, sequence, command)
        result = run_command(events, sequence, command)
        publish_complete(events, sequence, command, result.status, received_at)
      end
      
      private def publish_started(events, sequence, command) : Nil
        started_at = Time.instant
        TmuxREPL.publish_event(events, "started", @session_name, sequence, command: command)
        TmuxREPL.trace_timing(
          @session_name, "worker", "started_event_confirmed", started_at,
          "sequence=#{sequence}"
        )
      end
      
      private def run_command(events, sequence, command)
        run_started_at = Time.instant
        output_chunks = 0
        output_bytes = 0
        output_publish_ms = 0.0
        trace_timing = TmuxREPL.trace_timing_enabled?
      
        result = @session.run(command) do |chunk|
          output_chunks += 1
          output_bytes += chunk.bytesize
      
          if trace_timing
            output_publish_ms += publish_output(events, sequence, chunk)
          else
            TmuxREPL.publish_event(events, "output", @session_name, sequence, chunk: chunk)
          end
        end
      
        TmuxREPL.trace_timing(
          @session_name, "worker", "pty_run_finished", run_started_at,
          "sequence=#{sequence} status=#{result.status} output_chunks=#{output_chunks} output_bytes=#{output_bytes} output_publish_ms=#{output_publish_ms.round(2)}"
        )
        result
      end
      
      private def publish_output(events, sequence, chunk) : Float64
        started_at = Time.instant
        TmuxREPL.publish_event(events, "output", @session_name, sequence, chunk: chunk)
        (Time.instant - started_at).total_milliseconds
      end
      
      private def publish_complete(events, sequence, command, status, received_at) : Nil
        completed_at = Time.instant
        TmuxREPL.publish_event(events, "complete", @session_name, sequence, command: command, status: status)
        TmuxREPL.trace_timing(
          @session_name, "worker", "complete_event_confirmed", completed_at,
          "sequence=#{sequence}"
        )
        TmuxREPL.trace_timing(
          @session_name, "worker", "command_processing_finished", received_at,
          "sequence=#{sequence}"
        )
      end
    end
  
    module Lifecycle
      private def prepare_startup : Nil
        File.delete(@startup_error_path) if File.exists?(@startup_error_path)
        write_startup_stage("connecting to LavinMQ")
      end
      
      private def install_shutdown_handler : Nil
        Process.on_terminate do |_reason|
          @shutdown.send(nil)
        end
      end
      
      private def start_pty : Nil
        write_startup_stage("starting PTY session")
        @session.start
      end
      
      private def advertise_ready : Nil
        File.write(@ready_path, Process.pid.to_s)
        File.delete(@startup_stage_path) if File.exists?(@startup_stage_path)
      end
      
      private def wait_for_tmux_session(server : Tmux::Server) : Nil
        # The worker belongs to the tmux session, not to a pane or client.
        # Detaching therefore leaves the worker running.
        loop do
          sleep 5.seconds
          break unless server.cmd("has-session", "-t", @tmux_session_id).success?
      
          select
          when @shutdown.receive
            break
          when timeout(250.milliseconds)
          end
        end
      end
      
      private def tmux_server : Tmux::Server
        ENV["TMUX"]?.nil? ? Tmux::Server.new : Tmux::Server.from_env
      end
      
      private def write_startup_stage(stage : String) : Nil
        File.write(@startup_stage_path, stage)
      end
      
      private def report_startup_error(exception : Exception) : Nil
        File.write(@startup_error_path, "#{exception.class}: #{exception.message}")
        STDERR.puts "tmux.repl.worker: #{exception.class}: #{exception.message}"
      end
      
      private def cleanup : Nil
        begin
          @session.terminate
        rescue
        end
        File.delete(@ready_path) if File.exists?(@ready_path)
      end
    end
  
    module Messaging
      private def connect
        channel = Global.amqp_channel
        channel.prefetch(10)
      
        write_startup_stage("declaring command stream")
        commands = TmuxREPL.stream_queue(channel, TmuxREPL.commands_queue_name(@session_name))
      
        write_startup_stage("declaring event stream")
        events = TmuxREPL.stream_queue(channel, TmuxREPL.events_queue_name(@session_name))
        {commands, events}
      end
      
      private def subscribe(commands, events) : Nil
        commands.subscribe(
          no_ack: false,
          block: false,
          args: AMQ::Protocol::Table.new({"x-stream-offset" => "next"} of String => AMQ::Protocol::Field)
        ) do |message|
          begin
            data = JSON.parse(message.body_io.to_s)
            process_message(data, events) if data["type"].as_s == "command"
            message.ack
          rescue ex
            STDERR.puts "tmux.repl.worker: command failed: #{ex.message}"
            begin
              message.reject(requeue: false)
            rescue
            end
          end
        end
        nil
      end
    end
  
    def initialize(@session_name : String, @tmux_session_id : String)
      @shutdown = Channel(Nil).new(1)
      @session = PTY::Session.new(:sh)
    
      base = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
      @state_dir = File.join(base, "tmux-repl", @session_name)
      @ready_path = File.join(@state_dir, "worker.pid")
      @startup_error_path = File.join(@state_dir, "worker.error")
      @startup_stage_path = File.join(@state_dir, "worker.startup")
    end
    
    def run : Nil
      prepare_startup
      install_shutdown_handler
    
      begin
        commands, events = connect
        start_pty
        subscribe(commands, events)
        server = tmux_server
        advertise_ready
        wait_for_tmux_session(server)
      rescue ex
        report_startup_error(ex)
        exit 1
      ensure
        cleanup
      end
    end
    
    include Lifecycle
    include Messaging
    include Command
  end
end