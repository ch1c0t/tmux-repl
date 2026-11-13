require "../../src/output"

describe Output::View do
  it "returns the complete selected output in the active representation" do
    view = Output::View.new

    view.update(JSON.parse(%({"type":"input","sequence":1,"command":"run task"})))
    raw_output = "START_MARK_1\\nfirst line\\nsecond line\\nEND_MARK_1__0__"
    clean_output = "first line\\nsecond line\\n"
    view.update(JSON.parse({"type" => "output", "sequence" => 1, "chunk" => raw_output}.to_json))
    view.update(JSON.parse({"type" => "complete", "sequence" => 1, "status" => 0, "clean_output" => clean_output}.to_json))

    view.current_output.should eq(clean_output)

    view.toggle_view
    view.current_output.should eq(raw_output)

    view.update(JSON.parse(%({"type":"input","sequence":2,"command":"stream task"})))
    streamed_output = "current stream output\\n"
    view.update(JSON.parse({"type" => "output", "sequence" => 2, "chunk" => streamed_output}.to_json))
    view.current_output.should eq(streamed_output)
  end

  it "returns nil when no input has been selected" do
    Output::View.new.current_output.should be_nil
  end
end
