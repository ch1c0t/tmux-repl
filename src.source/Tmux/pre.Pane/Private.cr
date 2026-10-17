private def formatted_value(format : String) : String
  @server.run!("display-message", "-p", "-t", @pane_id, format).stdout.chomp
end
