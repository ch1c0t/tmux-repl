class State
  MANIFEST_NAME = "session.yml"
  LOG_DIRECTORY = "logs"
  RUNTIME_FILES = [
    "input.pid",
    "input.startup",
    "output.pid",
    "output.startup",
    "worker.pid",
    "worker.startup",
    "output.log",
  ]

  getter session_name : String
  getter base_path : String

  def initialize(@session_name : String)
    @base_path = self.class.session_path(@session_name)
  end

  private def initialize(@session_name : String, @base_path : String)
  end

  # Create the session directory and its manifest before any companion process
  # starts. A manifest already present must describe this exact session.
  def prepare : Nil
    FileUtils.mkdir_p(self.class.application_root)
    File.chmod(self.class.application_root, 0o700)

    FileUtils.mkdir_p(self.class.sessions_path)
    File.chmod(self.class.sessions_path, 0o700)

    FileUtils.mkdir_p(@base_path)
    File.chmod(@base_path, 0o700)

    FileUtils.mkdir_p(logs_path)
    File.chmod(logs_path, 0o700)

    if File.exists?(manifest_path)
      existing = self.class.read(@base_path)
      unless existing.session_name == @session_name
        raise "Session state directory #{@base_path.inspect} belongs to #{existing.session_name.inspect}"
      end
    else
      File.write(manifest_path, manifest_contents)
      File.chmod(manifest_path, 0o600)
    end
  end

  def manifest_path : String
    path(MANIFEST_NAME)
  end

  def path(name : String) : String
    File.join(@base_path, name)
  end

  # Diagnostic files live separately from short-lived process markers.
  def log_path(name : String) : String
    if name.empty? || File.basename(name) != name || name == "." || name == ".."
      raise ArgumentError.new("Log name must be a simple file name: #{name.inspect}")
    end

    FileUtils.mkdir_p(logs_path)
    File.join(logs_path, name)
  end

  # Stop removes transient runtime files but retains the manifest, error
  # diagnostics, and logs so a session can still be inspected afterwards.
  def cleanup_runtime : Nil
    RUNTIME_FILES.each do |name|
      file = path(name)
      File.delete(file) if File.exists?(file)
    end
  end

  def self.application_root : String
    state_home = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
    File.join(File.expand_path(state_home), "tmux.repl")
  end

  def self.sessions_path : String
    File.join(application_root, "sessions")
  end

  def self.smoke_tests_path : String
    File.join(application_root, "smoke-tests")
  end

  def self.session_path(session_name : String) : String
    File.join(sessions_path, directory_name(session_name))
  end

  # Read an existing session manifest without needing its original Tmux name.
  def self.read(base_path : String) : self
    expanded_path = File.expand_path(base_path)
    yaml_path = File.join(expanded_path, MANIFEST_NAME)
    raise "Session manifest not found at #{yaml_path}" unless File.exists?(yaml_path)

    manifest = YAML.parse(File.read(yaml_path))
    session_name = manifest["session_name"].as_s
    recorded_base_path = File.expand_path(manifest["base_path"].as_s)

    unless recorded_base_path == expanded_path
      raise "Session manifest at #{yaml_path} records base_path #{recorded_base_path.inspect}, not #{expanded_path.inspect}"
    end

    new(session_name, recorded_base_path)
  end

  # Companion processes prefer the explicit path supplied by the manager.
  # The deterministic lookup is a fallback for manually launched processes.
  def self.open(session_name : String) : self
    base_path = ENV["TMUX_REPL_SESSION_STATE"]? || session_path(session_name)
    state = read(base_path)

    unless state.session_name == session_name
      raise "Session state at #{base_path.inspect} belongs to #{state.session_name.inspect}, not #{session_name.inspect}"
    end

    state
  end

  # Location used by releases predating the session manifest. Kept only so
  # stop can terminate a worker left behind by an older tmux.repl process.
  def self.legacy_path(session_name : String) : String
    state_home = ENV["XDG_STATE_HOME"]? || File.join(ENV["HOME"]? || ".", ".local", "state")
    File.join(File.expand_path(state_home), "tmux-repl", session_name)
  end

  private def self.directory_name(session_name : String) : String
    slug = session_name.gsub(/[^a-zA-Z0-9_-]+/, "-")
    slug = slug.gsub(/-+/, "-").gsub(/\A[-_.]+|[-_.]+\z/, "")
    slug = "session" if slug.empty?
    slug = slug[0, 48]

    "#{slug}-#{Digest::SHA256.hexdigest(session_name)[0, 12]}"
  end

  private def logs_path : String
    File.join(@base_path, LOG_DIRECTORY)
  end

  private def manifest_contents : String
    YAML.build do |yaml|
      yaml.mapping do
        yaml.scalar "session_name"
        yaml.scalar @session_name
        yaml.scalar "base_path"
        yaml.scalar @base_path
      end
    end
  end
end
