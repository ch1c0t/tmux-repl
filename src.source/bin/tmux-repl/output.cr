module TmuxRepl
  def self.write_result(path : String, result : Result) : Nil
    File.open(path, "w") do |io|
      io.puts "$ #{result.command}"
      io.print result.stdout unless result.stdout.empty?
      io.print result.stderr unless result.stderr.empty?
      last = result.stderr.empty? ? result.stdout : result.stderr
      io.puts unless last.empty? || last.ends_with?("\n")
      io.puts "[exit status: #{result.status}]"
    end
  end
end