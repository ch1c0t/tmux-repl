private def formatted_value(format : String) : String
  @server.run!("display-message", "-p", "-t", @window_id, format).stdout.chomp
end
