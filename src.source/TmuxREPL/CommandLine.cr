# Tokenize a custom command without invoking a shell.
# Single/double quotes group arguments; backslash escapes outside single quotes.
def self.parse(line : String) : Array(String)
  arguments = [] of String
  token = String::Builder.new
  token_started = false
  quote : Char? = nil
  escaped = false

  line.each_char do |character|
    if escaped
      token << character
      escaped = false
      token_started = true
    elsif quote == '\''
      if character == '\''
        quote = nil
      else
        token << character
      end
    elsif quote == '"'
      case character
      when '"'
        quote = nil
      when '\\'
        escaped = true
      else
        token << character
      end
    elsif character == '\'' || character == '"'
      quote = character
      token_started = true
    elsif character == '\\'
      escaped = true
      token_started = true
    elsif character.whitespace?
      if token_started
        arguments << token.to_s
        token = String::Builder.new
        token_started = false
      end
    else
      token << character
      token_started = true
    end
  end

  raise ArgumentError.new("Trailing escape in command") if escaped
  raise ArgumentError.new("Unterminated quote in command") if quote

  arguments << token.to_s if token_started
  arguments
end
