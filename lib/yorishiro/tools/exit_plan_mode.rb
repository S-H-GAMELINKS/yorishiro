# frozen_string_literal: true

module Yorishiro
  module Tools
    # A plan-mode-only tool the model calls to signal that it has finished
    # researching and is ready to present its implementation plan. Calling it
    # is what breaks the plan loop, so the model has an explicit way to stop
    # reading files instead of looping on read-only tools forever.
    class ExitPlanMode < Tool
      def read_only?
        true
      end

      def name
        "exit_plan_mode"
      end

      def description
        "Call this tool once you have finished researching and are ready to " \
          "present your implementation plan to the user for approval. Pass the " \
          "complete plan as the `plan` argument. As soon as you understand the " \
          "task, STOP calling read-only tools (read_file, list_files) and call " \
          "this tool instead."
      end

      def parameters
        {
          type: "object",
          properties: {
            plan: { type: "string", description: "The complete implementation plan as markdown text" }
          },
          required: ["plan"]
        }
      end

      def execute(**params)
        params[:plan] || params["plan"] || ""
      end
    end
  end
end
