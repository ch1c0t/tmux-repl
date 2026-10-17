def capture_pane(start : String? = nil, finish : String? = nil, escape_sequences : Bool = false, join_wrapped : Bool = false) : Array(String)
  args = ["capture-pane", "-p", "-t", @pane_id]
  args.concat(["-S", start]) if start
  args.concat(["-E", finish]) if finish
  args << "-e" if escape_sequences
  args << "-J" if join_wrapped
  @server.run!(args).stdout_lines
end
