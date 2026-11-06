@output = String::Builder.new

def initialize(
  @session_name : String,
  @sequence : UInt64,
  @events : AMQP::Client::Queue
)
end

# Publish a chunk immediately so long-running handlers can stream progress.
def write(chunk : String) : Nil
  return if chunk.empty?

  @output << chunk
  TmuxREPL.publish_event(
    @events,
    "output",
    @session_name,
    @sequence,
    chunk: chunk
  )
end

def puts(value : String = "") : Nil
  write("#{value}\n")
end

def output : String
  @output.to_s
end
