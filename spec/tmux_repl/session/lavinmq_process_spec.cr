require "./helper"
require "./lavinmq_process/scenario"

describe "LavinMQ-backed REPL processes" do
  it "keeps input history and streams, strips, and toggles command output" do
    LavinMQProcess::Scenario.new.run
  end
end
