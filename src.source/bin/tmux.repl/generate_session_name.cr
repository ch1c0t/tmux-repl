def generate_session_name : String
  name_parts = [] of String

  if ENV["TMUX"]?
    caller_session = Tmux::Session.from_env.session_name
    name_parts << caller_session << "|" << "repl"
  else
    name_parts << "repl"
  end

  name_parts << "-" << timestamp

  name_parts.join
end

def timestamp
  now = Time.local
  string = now.to_s("%Y%m%d-%H%M%S")
  string += "-#{now.nanosecond.to_s.rjust(9, '0')}"
  string
end
