# frozen_string_literal: true

module Yorishiro
  # Runs a delegated task in its own fresh Conversation so exploratory tool
  # output never enters the parent conversation — only the final assistant
  # text is returned. The caller decides which tools the subagent may use;
  # Tools::Task passes read-only tools only, so no permission prompts fire.
  class SubAgent
    MAX_ITERATIONS = 15

    SYSTEM_PROMPT = <<~PROMPT
      You are a subagent handling a task delegated by a coding assistant.
      Investigate using the available read-only tools, then reply with your
      findings as plain text. Only your final message is returned to the
      caller, so make it complete and self-contained. Do not ask questions —
      nobody can answer them.
    PROMPT

    def initialize(provider:, tools:, output: $stdout,
                   hooks: Yorishiro.configuration.hooks,
                   max_iterations: MAX_ITERATIONS)
      @provider = provider
      @tools = tools
      @output = output
      @hooks = hooks
      @max_iterations = max_iterations
    end

    # Run the agent loop for +prompt+ and return the final assistant text.
    def run(prompt)
      conversation = Conversation.new(system_prompt: SYSTEM_PROMPT)
      conversation.add_message(:user, prompt)
      last_content = nil

      @max_iterations.times do |iteration|
        manage_context!(conversation)

        begin
          result = @provider.chat(conversation, tools: @tools.map(&:definition))
        rescue StandardError => e
          # A failed completion must not throw away the investigation done so
          # far — salvage it the same way the iteration limit does.
          return provider_error_notice(last_content, e)
        end
        content = result[:content]
        tool_calls = result[:tool_calls]

        conversation.add_message(:assistant, content, tool_calls: tool_calls.empty? ? nil : tool_calls)
        last_content = content unless content.to_s.empty?

        return final_answer(content) if tool_calls.empty?

        # Pending tool calls on the last iteration are pointless to execute —
        # there is no follow-up completion to consume their results.
        break if iteration == @max_iterations - 1

        execute_tool_calls(conversation, tool_calls)
      end

      iteration_limit_notice(last_content)
    end

    private

    # Same escalation as the CLI minus compaction (an extra LLM call is
    # overkill for a short-lived loop) and minus the "[i]" notices — the
    # subagent shrinks its context silently.
    def manage_context!(conversation)
      budget = @provider.context_budget_tokens
      return unless budget

      conversation.elide_old_tool_results!(max_tokens: budget)
      conversation.trim_to_budget!(max_tokens: budget)
    end

    def final_answer(content)
      content.to_s.empty? ? "The subagent returned no findings." : content
    end

    def iteration_limit_notice(last_content)
      notice = "[Subagent reached the #{@max_iterations}-iteration limit without a final answer.]"
      last_content ? "#{last_content}\n\n#{notice}" : notice
    end

    def provider_error_notice(last_content, error)
      notice = "[Subagent stopped early after a provider error: #{error.message}]"
      last_content ? "#{last_content}\n\n#{notice}" : notice
    end

    def execute_tool_calls(conversation, tool_calls)
      tool_calls.each do |tc|
        @output.puts "  [task] #{tc[:name]}(#{format_args(tc[:arguments])})"

        denial = @hooks.run_before_tool_use(tc[:name], tc[:arguments])
        if denial
          conversation.add_tool_result(tool_call_id: tc[:id], content: "Tool call denied by hook: #{denial.reason}")
          next
        end

        tool = @tools.find { |t| t.name == tc[:name] }
        unless tool
          conversation.add_tool_result(tool_call_id: tc[:id], content: "Error: Unknown tool '#{tc[:name]}'")
          next
        end

        run_tool(conversation, tool, tc)
      end
    end

    def run_tool(conversation, tool, tool_call)
      output = tool.execute(**symbolize_keys(tool_call[:arguments]))
      conversation.add_tool_result(
        tool_call_id: tool_call[:id],
        content: ToolResultCap.cap(output, budget: @provider.context_budget_tokens)
      )
      run_after_hooks(tool_call, output) # hooks (e.g. audit logs) see the full output
    rescue StandardError => e
      conversation.add_tool_result(tool_call_id: tool_call[:id], content: "Error: #{e.message}")
    end

    # after hooks are observational: a failure is warned about but never
    # alters the already-recorded tool result.
    def run_after_hooks(tool_call, output)
      @hooks.run_after_tool_use(tool_call[:name], tool_call[:arguments], output)
    rescue StandardError => e
      @output.puts "[!] after_tool_use hook error: #{e.message}"
    end

    def format_args(args)
      return "" unless args

      args.map { |k, v| "#{k}: #{truncate(v.to_s, 50)}" }.join(", ")
    end

    def truncate(str, max)
      str.length > max ? "#{str[0...max]}..." : str
    end

    def symbolize_keys(hash)
      hash.transform_keys(&:to_sym)
    end
  end
end
