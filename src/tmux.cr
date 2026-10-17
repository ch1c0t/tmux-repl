require "process"

module Tmux
  class Error < Exception
  end

  class CommandError < Error
    getter result : CommandResult

    def initialize(@result : CommandResult)
      detail = @result.stderr.strip
      detail = "exit status #{@result.exit_code}" if detail.empty?
      super("tmux command failed (#{@result.exit_code}): #{detail}")
    end
  end

  class NotInsideTmux < Error
  end

  struct CommandResult
    getter args : Array(String)
    getter stdout : String
    getter stderr : String
    getter exit_code : Int32

    def initialize(@args : Array(String), @stdout : String, @stderr : String, @exit_code : Int32)
    end

    def success? : Bool
      @exit_code == 0
    end

    def stdout_lines : Array(String)
      @stdout.lines
    end

    def stderr_lines : Array(String)
      @stderr.lines
    end
  end

  class Client
    getter binary : String

    def initialize(binary : String = "tmux", socket_name : String? = nil, socket_path : String? = nil)
      raise Error.new("Specify socket_name or socket_path, not both") if socket_name && socket_path

      @binary = binary
      @server_options = [] of String
      @server_options.concat(["-L", socket_name]) if socket_name
      @server_options.concat(["-S", socket_path]) if socket_path
    end

    def run(*args : String) : CommandResult
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(@binary, @server_options + args.to_a, output: stdout, error: stderr)
      CommandResult.new(args.to_a, stdout.to_s, stderr.to_s, status.exit_code)
    rescue ex
      raise Error.new("Unable to execute #{@binary}: #{ex.message || ex.class.name}")
    end

    def run!(*args : String) : CommandResult
      result = run(*args)
      raise CommandError.new(result) unless result.success?
      result
    end

    def interactive!(*args : String) : Nil
      status = Process.run(@binary, @server_options + args.to_a)
      raise Error.new("tmux command failed (#{status.exit_code})") unless status.success?
    rescue ex
      raise ex if ex.is_a?(Error)
      raise Error.new("Unable to execute #{@binary}: #{ex.message || ex.class.name}")
    end
  end

  class Server
    module Private
      private def no_sessions_result?(result : CommandResult) : Bool
        return false if result.success?
        message = "#{result.stderr} #{result.stdout}".downcase
        message.includes?("no server running") || message.includes?("no sessions")
      end

      private def session_ids : Array(String)
        result = @client.run("list-sessions", "-F", "\#{session_id}")
        return [] of String if no_sessions_result?(result)
        raise CommandError.new(result) unless result.success?
        result.stdout_lines.reject(&.empty?)
      end
    end

    module Public
      def cmd(*args : String) : CommandResult
        @client.run(*args)
      end

      def run!(*args : String) : CommandResult
        @client.run!(*args)
      end

      def sessions : Array(Session)
        session_ids.map { |id| Session.new(self, id) }
      end

      def session(selector : String) : Session
        sessions.each do |item|
          return item if item.session_id == selector || item.session_name == selector
        end
        raise Error.new("No tmux session matches #{selector.inspect}")
      end

      def new_session(name : String? = nil, detached : Bool = true, window_name : String? = nil, start_directory : String? = nil) : Session
        args = ["new-session", "-d", "-P", "-F", "\#{session_id}"]
        args.concat(["-s", name]) if name
        args.concat(["-n", window_name]) if window_name
        args.concat(["-c", start_directory]) if start_directory
        id = run!(*args).stdout.strip
        raise Error.new("tmux did not return a session ID") if id.empty?
        session = Session.new(self, id)
        session.attach unless detached
        session
      end

      def windows : Array(Window)
        result = [] of Window
        sessions.each { |item| result.concat(item.windows) }
        result
      end

      def panes : Array(Pane)
        result = [] of Pane
        windows.each { |item| result.concat(item.panes) }
        result
      end

      def kill_server : CommandResult
        run!("kill-server")
      end
    end

    getter client : Client

    def initialize(socket_name : String? = nil, socket_path : String? = nil, binary : String = "tmux")
      @client = Client.new(binary, socket_name, socket_path)
    end

    def self.from_env(binary : String = "tmux") : Server
      value = ENV["TMUX"]? || raise NotInsideTmux.new("TMUX is not set; not inside tmux")
      path = value.split(",", 2).first
      raise NotInsideTmux.new("TMUX does not contain a socket path") if path.empty?
      new(nil, path, binary)
    end

    include Private
    include Public
  end

  class Session
    module Private
      private def formatted_value(format : String) : String
        @server.run!("display-message", "-p", "-t", @session_id, format).stdout.chomp
      end
    end

    module Public
      def session_name : String
        formatted_value("\#{session_name}")
      end

      def windows : Array(Window)
        format = "\#{window_id}"
        output = @server.run!("list-windows", "-t", @session_id, "-F", format)
        output.stdout_lines.reject(&.empty?).map { |id| Window.new(@server, @session_id, id) }
      end

      def active_window : Window
        id = formatted_value("\#{window_id}")
        windows.each { |item| return item if item.window_id == id }
        raise Error.new("Session #{@session_id} has no active window")
      end

      def new_window(name : String? = nil, detached : Bool = true, start_directory : String? = nil) : Window
        args = ["new-window", "-t", @session_id, "-P", "-F", "\#{window_id}"]
        args << "-d" if detached
        args.concat(["-n", name]) if name
        args.concat(["-c", start_directory]) if start_directory
        id = @server.run!(*args).stdout.strip
        raise Error.new("tmux did not return a window ID") if id.empty?
        Window.new(@server, @session_id, id)
      end

      def rename(name : String) : Session
        @server.run!("rename-session", "-t", @session_id, name)
        self
      end

      def attach : Nil
        @server.client.interactive!("attach-session", "-t", @session_id)
      end

      def kill : CommandResult
        @server.run!("kill-session", "-t", @session_id)
      end
    end

    getter server : Server
    getter session_id : String

    def initialize(@server : Server, @session_id : String)
    end

    def self.from_env(binary : String = "tmux") : Session
      Pane.from_env(binary).session
    end

    include Private
    include Public
  end

  class Window
    module Private
      private def formatted_value(format : String) : String
        @server.run!("display-message", "-p", "-t", @window_id, format).stdout.chomp
      end
    end

    module Public
      def session : Session
        Session.new(@server, @session_id)
      end

      def window_name : String
        formatted_value("\#{window_name}")
      end

      def window_index : Int32
        formatted_value("\#{window_index}").to_i
      end

      def active? : Bool
        session.active_window.window_id == @window_id
      end

      def panes : Array(Pane)
        format = "\#{pane_id}"
        result = @server.run!("list-panes", "-t", @window_id, "-F", format)
        result.stdout_lines.reject(&.empty?).map { |id| Pane.new(@server, @session_id, @window_id, id) }
      end

      def active_pane : Pane
        id = @server.run!("display-message", "-p", "-t", @window_id, "\#{pane_id}").stdout.strip
        panes.each { |item| return item if item.pane_id == id }
        raise Error.new("Window #{@window_id} has no active pane")
      end

      def split(direction : Symbol = :right, size : Int32? = nil, start_directory : String? = nil, detached : Bool = true) : Pane
        active_pane.split(direction, size, start_directory, detached)
      end

      def rename(name : String) : Window
        @server.run!("rename-window", "-t", @window_id, name)
        self
      end

      def select_layout(layout : String) : Window
        @server.run!("select-layout", "-t", @window_id, layout)
        self
      end

      def resize(width : Int32? = nil, height : Int32? = nil) : Window
        raise ArgumentError.new("Specify width, height, or both") unless width || height
        args = ["resize-window", "-t", @window_id]
        args.concat(["-x", width.to_s]) if width
        args.concat(["-y", height.to_s]) if height
        @server.run!(*args)
        self
      end

      def kill : CommandResult
        @server.run!("kill-window", "-t", @window_id)
      end
    end

    getter server : Server
    getter session_id : String
    getter window_id : String

    def initialize(@server : Server, @session_id : String, @window_id : String)
    end

    def self.from_env(binary : String = "tmux") : Window
      Pane.from_env(binary).window
    end

    include Private
    include Public
  end

  class Pane
    module Private
      private def formatted_value(format : String) : String
        @server.run!("display-message", "-p", "-t", @pane_id, format).stdout.chomp
      end
    end

    module Public
      def window : Window
        Window.new(@server, @session_id, @window_id)
      end

      def session : Session
        Session.new(@server, @session_id)
      end

      def pane_index : Int32
        formatted_value("\#{pane_index}").to_i
      end

      def current_command : String
        formatted_value("\#{pane_current_command}")
      end

      def current_path : String
        formatted_value("\#{pane_current_path}")
      end

      def width : Int32
        formatted_value("\#{pane_width}").to_i
      end

      def height : Int32
        formatted_value("\#{pane_height}").to_i
      end

      def active? : Bool
        window.active_pane.pane_id == @pane_id
      end

      def split(direction : Symbol = :right, size : Int32? = nil, start_directory : String? = nil, detached : Bool = true) : Pane
        args = ["split-window", "-P", "-F", "\#{pane_id}", "-t", @pane_id]
        case direction
        when :right
          args << "-h"
        when :left
          args.concat(["-h", "-b"])
        when :below
          args << "-v"
        when :above
          args.concat(["-v", "-b"])
        else
          raise ArgumentError.new("direction must be :right, :left, :above, or :below")
        end
        args << "-d" if detached
        args.concat(["-l", size.to_s]) if size
        args.concat(["-c", start_directory]) if start_directory
        id = @server.run!(*args).stdout.strip
        raise Error.new("tmux did not return a pane ID") if id.empty?
        Pane.new(@server, @session_id, @window_id, id)
      end

      def send_keys(keys : String, enter : Bool = true, literal : Bool = false) : Pane
        if literal
          @server.run!("send-keys", "-t", @pane_id, "-l", keys)
          @server.run!("send-keys", "-t", @pane_id, "Enter") if enter
        else
          args = ["send-keys", "-t", @pane_id, keys]
          args << "Enter" if enter
          @server.run!(*args)
        end
        self
      end

      def enter : Pane
        @server.run!("send-keys", "-t", @pane_id, "Enter")
        self
      end

      def capture_pane(start : String? = nil, finish : String? = nil, escape_sequences : Bool = false, join_wrapped : Bool = false) : Array(String)
        args = ["capture-pane", "-p", "-t", @pane_id]
        args.concat(["-S", start]) if start
        args.concat(["-E", finish]) if finish
        args << "-e" if escape_sequences
        args << "-J" if join_wrapped
        @server.run!(*args).stdout_lines
      end

      def display_message(format : String) : String
        formatted_value(format)
      end

      def select : Pane
        @server.run!("select-pane", "-t", @pane_id)
        self
      end

      def resize(width : Int32? = nil, height : Int32? = nil) : Pane
        raise ArgumentError.new("Specify width, height, or both") unless width || height
        args = ["resize-pane", "-t", @pane_id]
        args.concat(["-x", width.to_s]) if width
        args.concat(["-y", height.to_s]) if height
        @server.run!(*args)
        self
      end

      def clear_history : Pane
        @server.run!("clear-history", "-t", @pane_id)
        self
      end

      def kill : CommandResult
        @server.run!("kill-pane", "-t", @pane_id)
      end
    end

    getter server : Server
    getter session_id : String
    getter window_id : String
    getter pane_id : String

    def initialize(@server : Server, @session_id : String, @window_id : String, @pane_id : String)
    end

    def self.from_env(binary : String = "tmux") : Pane
      pane_id = ENV["TMUX_PANE"]? || raise NotInsideTmux.new("TMUX_PANE is not set; not inside a tmux pane")
      server = Server.from_env(binary)
      format = "\#{session_id}\t\#{window_id}"
      result = server.cmd("display-message", "-p", "-t", pane_id, format)
      raise CommandError.new(result) unless result.success?
      values = result.stdout.chomp.split('\t')
      raise Error.new("Could not resolve TMUX_PANE=#{pane_id}") unless values.size == 2
      new(server, values[0], values[1], pane_id)
    end

    include Private
    include Public
  end
end
