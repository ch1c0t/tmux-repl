def execute_steps : Nil
  run_steps
end

def run_steps : Nil
end

macro inherited
  def run_steps : Nil
    super
  end
end

macro step(name, &block)
  def run_steps : Nil
    previous_def
    record_step({{name}}) do
      {{block.body}}
    end
  end
end
