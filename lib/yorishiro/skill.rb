# frozen_string_literal: true

module Yorishiro
  class Skill
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
