# frozen_string_literal: true

module Yorishiro
  # Caps a tool result before it enters a conversation so a single huge
  # output (a whole file, a big command dump) cannot exhaust a small
  # context window. Scaled to the provider budget when one is known.
  # Shared by the CLI agent loop and subagents.
  module ToolResultCap
    # Tool-result size caps used when the provider reports no context
    # budget (cloud models) and as the floor when it does.
    DEFAULT_TOOL_RESULT_CHARS = 30_000
    MIN_TOOL_RESULT_CHARS = 2_000

    module_function

    def cap(output, budget:)
      limit = max_chars(budget)
      return output if output.to_s.length <= limit

      "#{output[0...limit]}\n... (tool output truncated: showing #{limit} of #{output.length} characters. " \
        "Narrow the request — offset/limit, a glob, or a more specific pattern — to see the rest.)"
    end

    # One tool result may take at most a quarter of the context budget.
    def max_chars(budget)
      return DEFAULT_TOOL_RESULT_CHARS unless budget

      [budget * Conversation::CHARS_PER_TOKEN / 4, MIN_TOOL_RESULT_CHARS].max
    end
  end
end
