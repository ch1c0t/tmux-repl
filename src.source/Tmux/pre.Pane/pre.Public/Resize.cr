def resize(width : Int32? = nil, height : Int32? = nil) : Pane
  raise ArgumentError.new("Specify width, height, or both") unless width || height
  args = ["resize-pane", "-t", @pane_id]
  args.concat(["-x", width.to_s]) if width
  args.concat(["-y", height.to_s]) if height
  @server.run!(args)
  self
end
