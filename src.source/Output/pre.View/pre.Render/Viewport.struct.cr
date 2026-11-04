# The viewport owns scrolling, visible-line selection, and logical line numbering.
getter lines : Array(String)
getter total_lines : Int32
getter first_line : Int32?
getter last_line : Int32?

def initialize(
  @lines : Array(String),
  @total_lines : Int32,
  @first_line : Int32?,
  @last_line : Int32?
)
end

def line_summary(completed : Bool) : String
  if @total_lines == 0
    completed ? "[0 output lines]" : "[0 output lines so far]"
  elsif first = @first_line
    last = @last_line.not_nil!
    progress = completed ? "" : " so far"
    "[Output lines #{first}–#{last} of #{@total_lines}#{progress}]"
  else
    "[0 of #{@total_lines} output lines visible]"
  end
end
