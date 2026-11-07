  def latest_ocr : String
    "SCREEN OCR: fixture display is ready"
  end

  def send_key(action : String, key : String) : String
    "KEY EVENT: #{action} #{key}"
  end
