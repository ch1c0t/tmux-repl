def send_keys(keys : String, enter : Bool = true, literal : Bool = false) : Pane
  if literal
    @server.run!("send-keys", "-t", @pane_id, "-l", keys)
    @server.run!("send-keys", "-t", @pane_id, "Enter") if enter
  else
    args = ["send-keys", "-t", @pane_id, keys]
    args << "Enter" if enter
    @server.run!(args)
  end
  self
end
