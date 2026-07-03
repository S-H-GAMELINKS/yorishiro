# frozen_string_literal: true

module Yorishiro
  class Skill
    # Returned from #execute to inject a prompt into the LLM instead of just
    # printing output. The CLI feeds +text+ to the model as a user message and
    # runs the agent/plan loop. Build one with the #prompt helper.
    Prompt = Struct.new(:text)

    # Convenience for subclasses: `prompt("...")` inside #execute returns a
    # Prompt so the returned text is sent to the LLM.
    def prompt(text)
      Prompt.new(text)
    end

    def name
      raise SkillNotImplementedError, "#{self.class}#name is not implemented"
    end

    def description
      raise SkillNotImplementedError, "#{self.class}#description is not implemented"
    end

    def execute(_context)
      raise SkillNotImplementedError, "#{self.class}#execute is not implemented"
    end
  end
end
