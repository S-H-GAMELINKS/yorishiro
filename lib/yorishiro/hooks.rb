# frozen_string_literal: true

module Yorishiro
  # Registry for lifecycle hooks declared in .yorishirorc via the `on` DSL.
  # before_tool_use / user_prompt_submit blocks can veto the action by
  # returning :deny or a Denial (built with the `deny("reason")` helper).
  # Any other return value (including nil) lets the action proceed, so
  # logging-only hooks are safe by default.
  class Hooks
    EVENTS = %i[before_tool_use after_tool_use user_prompt_submit].freeze

    Denial = Struct.new(:reason)

    def initialize
      @blocks = Hash.new { |hash, key| hash[key] = [] }
    end

    def on(event, &block)
      raise ConfigurationError, "Unknown hook event: #{event}. Available events: #{EVENTS.join(", ")}" unless EVENTS.include?(event)

      @blocks[event] << block
    end

    def any?(event)
      @blocks[event].any?
    end

    # Returns nil to proceed, or a Denial. A hook that raises denies the
    # call (fail closed) so a broken guard cannot silently let tools run.
    def run_before_tool_use(tool_name, arguments)
      first_denial(:before_tool_use, tool_name, arguments)
    end

    def run_user_prompt_submit(input)
      first_denial(:user_prompt_submit, input)
    end

    # Exceptions propagate to the caller: after hooks are observational,
    # so the CLI just warns and keeps the tool result.
    def run_after_tool_use(tool_name, arguments, result)
      @blocks[:after_tool_use].each { |block| block.call(tool_name, arguments, result) }
      nil
    end

    private

    def first_denial(event, *args)
      @blocks[event].each do |block|
        denial = to_denial(block.call(*args))
        return denial if denial
      rescue StandardError => e
        return Denial.new("hook raised #{e.class}: #{e.message}")
      end
      nil
    end

    def to_denial(value)
      case value
      when Denial then value
      when :deny then Denial.new("denied by hook")
      end
    end
  end
end
