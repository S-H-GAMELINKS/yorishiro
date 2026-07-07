# frozen_string_literal: true

module Yorishiro
  class Tool
    def name
      raise ToolNotImplementedError, "#{self.class}#name is not implemented"
    end

    def description
      raise ToolNotImplementedError, "#{self.class}#description is not implemented"
    end

    def parameters
      raise ToolNotImplementedError, "#{self.class}#parameters is not implemented"
    end

    def execute(**_params)
      raise ToolNotImplementedError, "#{self.class}#execute is not implemented"
    end

    def definition
      {
        name: name,
        description: description,
        input_schema: parameters
      }
    end

    def read_only?
      false
    end

    def permission_check(_arguments)
      :allowed
    end

    def configure(_options)
      # Override in subclasses to handle allow_tool options
    end

    # Return a human-readable preview of what execute would do (e.g. a
    # diff), shown in the permission prompt instead of the raw argument
    # dump. Return nil to keep the default argument dump.
    def preview(_arguments)
      nil
    end
  end
end
