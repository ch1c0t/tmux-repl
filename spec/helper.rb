require "open3"

def cli(arguments = "")
  binary = "./bin/tmux-repl"
  command = "#{binary} #{arguments}"
  stdout, stderr, status = Open3.capture3(command)

  unless status.success?
    raise "'#{command}' exited with exit code #{status.exitstatus}"
  end

  [stdout, stderr]
end
