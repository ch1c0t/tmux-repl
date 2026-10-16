require "reply"

module TmuxRepl
  def self.run_repl(path : String) : Nil
    reader = Reply::Reader.new
    reader.read_loop do |expression|
      next if expression.strip.empty?
      write_result(path, execute(expression))
    end
  end
end