# Discover shell commands from PATH without invoking a shell for each keystroke.
class CommandCompleter
  SHELL_BUILTINS = %w(
    . : alias bg break cd command continue echo eval exec exit export false
    fg getopts hash jobs kill local printf pwd read readonly return set shift
    test times trap true type ulimit umask unalias unset wait
  )

  getter commands : Array(String)

  def initialize(path : String = ENV["PATH"]? || "")
    names = {} of String => Bool
    SHELL_BUILTINS.each { |name| names[name] = true }

    path.split(':').each do |entry|
      directory = entry.empty? ? "." : entry

      begin
        Dir.children(directory).each do |name|
          next if name.empty? || name.includes?(' ') || name.includes?('\t') ||
                  name.includes?('\n') || name.includes?('\r')

          command_path = File.join(directory, name)
          info = File.info?(command_path)
          next unless info && info.file?
          next unless File::Info.executable?(command_path)

          names[name] = true
        end
      rescue
        # PATH may contain optional or inaccessible directories.
      end
    end

    @commands = names.keys.sort!
  end

  def complete(prefix : String) : Array(String)
    @commands.select { |command| command.starts_with?(prefix) }
  end
end
