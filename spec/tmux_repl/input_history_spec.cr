require "../../src/input"

describe Input::History do
  it "assigns increasing sequence numbers and selects the newest input" do
    history = Input::History.new

    first = history.add("first")
    second = history.add("second")

    first.should eq(1_u64)
    second.should eq(2_u64)
    history.entries.should eq([{1_u64, "first"}, {2_u64, "second"}])
    history.selected_sequence.should eq(2_u64)
  end

  it "selects only inputs that exist in its history" do
    history = Input::History.new
    history.add("first")

    history.select(1_u64).should be_true
    history.select(99_u64).should be_false
    history.selected_sequence.should eq(1_u64)
  end

  it "finds adjacent inputs without moving beyond either end" do
    history = Input::History.new
    history.add("first")
    history.add("second")
    history.add("third")

    history.previous_sequence.should eq(2_u64)
    history.select(1_u64)
    history.previous_sequence.should be_nil
    history.next_sequence.should eq(2_u64)
    history.select(3_u64)
    history.next_sequence.should be_nil
  end
end
