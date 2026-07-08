# frozen_string_literal: true

module Yorishiro
  module Tools
    class Task < Tool
      # Read-only: the subagent only ever receives read-only tools, so a
      # task can never mutate anything.
      def read_only?
        true
      end

      def name
        "task"
      end

      def description
        "Delegate a read-only research task to a subagent with its own fresh " \
          "context window. The subagent can read files, list files, and grep, " \
          "and returns a text summary of its findings. Use it for exploratory " \
          "work (finding where something is defined, summarizing several files) " \
          "to keep your own context small. The subagent cannot see this " \
          "conversation, so the prompt must be complete and self-contained."
      end

      def parameters
        {
          type: "object",
          properties: {
            description: {
              type: "string",
              description: "Short (3-7 word) label for the task"
            },
            prompt: {
              type: "string",
              description: "Complete, self-contained instructions: what to investigate and what to report back"
            }
          },
          required: ["prompt"]
        }
      end

      # Called by the CLI so the subagent reuses the session's provider and
      # prints its progress to the session's output.
      def attach(provider:, output:)
        @provider = provider
        @output = output
      end

      def execute(**params)
        prompt = params[:prompt] || params["prompt"]
        raise "prompt is required" if prompt.to_s.strip.empty?

        SubAgent.new(provider: provider, tools: child_tools, output: output).run(prompt)
      end

      private

      def provider
        @provider ||= Provider.build(Yorishiro.configuration)
      end

      def output
        @output || $stdout
      end

      # Read-only tools never prompt for permission, so the subagent loop
      # runs unattended. The task tool itself is excluded so subagents
      # cannot nest.
      def child_tools
        Yorishiro.configuration.allowed_tools.select(&:read_only?).grep_v(Task)
      end
    end
  end
end
