# frozen_string_literal: true

require "reline"
require "optparse"

module Yorishiro
  class CLI
    # Fraction of the context budget at which auto-compaction kicks in.
    COMPACT_THRESHOLD = 0.8

    # Env vars the /model command reads an API key from when switching to a
    # different provider. Ollama needs none.
    API_KEY_ENV = { anthropic: "ANTHROPIC_API_KEY", open_ai: "OPENAI_API_KEY" }.freeze

    def initialize
      @conversation = nil
      @provider = nil
      @plan_mode = false
      @output = $stdout
    end

    def start
      parse_options!
      setup!
      print_welcome
      repl_loop
    ensure
      @input_history&.save
      @mcp_manager&.stop_all
    end

    private

    def parse_options!
      @cli_opts = {}

      OptionParser.new do |opts|
        opts.banner = "Usage: yorishiro [options]"

        opts.on("--provider PROVIDER", "Provider (anthropic, open_ai, ollama)") do |v|
          @cli_opts[:provider] = v.to_sym
        end

        opts.on("--model MODEL", "Model name") do |v|
          @cli_opts[:model] = v
        end

        opts.on("--plan", "Start in plan mode") do
          @cli_opts[:plan_mode] = true
        end

        opts.on("--continue", "Resume the most recent session") do
          @cli_opts[:continue] = true
        end

        opts.on("--resume [ID]", "Resume a saved session (interactive picker when ID is omitted)") do |v|
          @cli_opts[:resume] = v || :pick
        end

        opts.on("--version", "Show version") do
          @output.puts "yorishiro #{Yorishiro::VERSION}"
          exit
        end

        opts.on("--help", "Show help") do
          @output.puts opts
          exit
        end
      end.parse!
    end

    def setup!
      config = Yorishiro.configuration
      config.load!

      apply_cli_overrides!(config)

      @provider = Provider.build(config)
      attach_tools!
      @plan_mode = @cli_opts.fetch(:plan_mode, config.plan_mode_enabled)
      @conversation = Conversation.new(system_prompt: config.system_prompt_text)

      @mcp_manager = MCP::ServerManager.new(
        server_configs: config.mcp_servers,
        configuration: config
      )
      @mcp_manager.start_all

      @input_history = InputHistory.new
      @input_history.load

      @session_store = SessionStore.new
      @session_id = nil
      resume_from_options!
    end

    # Route --provider/--model through switch! so the override is validated
    # (and rolled back on failure) instead of wiping the rc file's api_key
    # and model the way a bare use(provider:) would. Changing provider reads
    # the key from that provider's env var and drops the rc model, which
    # belongs to the old provider; --model alone keeps both.
    def apply_cli_overrides!(config)
      provider = @cli_opts[:provider]
      model = @cli_opts[:model]
      return unless provider || model

      provider ||= config.provider_name
      model ||= config.model if provider == config.provider_name
      config.switch!(provider: provider, model: model, api_key: resolve_api_key(provider))
    end

    # Hand the session's provider and output to tools that spawn their own
    # LLM loops (e.g. the task tool's subagent).
    def attach_tools!
      Yorishiro.configuration.allowed_tools.each do |tool|
        tool.attach(provider: @provider, output: @output) if tool.respond_to?(:attach)
      end
    end

    def print_welcome
      @output.puts "Yorishiro v#{VERSION} (#{Yorishiro.configuration.provider_name}:#{@provider.model_name})"
      @output.puts "Type your message (Enter twice to send, /help for commands)"
      @output.puts "Plan mode: ON" if @plan_mode
      @output.puts
    end

    def repl_loop
      loop do
        input = read_input
        break if input.nil?
        next if input.strip.empty?

        # Slash commands share the error handling: a skill can raise or
        # inject a prompt that runs the full agent loop, and neither may
        # take down the REPL. /exit still works — SystemExit is not a
        # StandardError.
        begin
          if input.strip.start_with?("/")
            handle_slash_command(input.strip)
          else
            process_user_input(input)
          end
        rescue Yorishiro::ProviderError => e
          @output.puts "\n[Error] #{e.message}"
        rescue StandardError => e
          @output.puts "\n[Error] #{e.class}: #{e.message}"
        end
      end
    rescue Interrupt
      @output.puts "\nGoodbye!"
    end

    # Read a (possibly multi-line) message in a single editable buffer so the
    # user can move the cursor back to earlier lines and edit them. Submitting
    # follows the existing "Enter on a blank line sends" gesture. Returns nil on
    # EOF (Ctrl-D) to terminate the REPL.
    def read_input
      buffer = Reline.readmultiline("you> ", true) do |input|
        # Reline appends the just-pressed newline before calling this block, so
        # a trailing blank line (Enter on an empty line) shows up as a double
        # newline. Submit then, provided some non-empty content was entered —
        # the existing "Enter on a blank line sends" gesture.
        !input.strip.empty? && input.end_with?("\n\n")
      end
      return nil if buffer.nil?

      @input_history.save
      buffer.strip
    end

    def process_user_input(input)
      denial = Yorishiro.configuration.hooks.run_user_prompt_submit(input)
      if denial
        @output.puts "[Hook] Prompt blocked: #{denial.reason}"
        return
      end

      @conversation.add_message(:user, input)

      if @plan_mode
        plan_then_execute
      else
        agent_loop
      end
    ensure
      # Save even when the turn raised, so a crash loses at most the
      # in-flight completion.
      persist_session
    end

    def agent_loop
      loop do
        tools = Yorishiro.configuration.tool_definitions

        result = request_completion(tools)

        content = result[:content]
        tool_calls = result[:tool_calls]

        @conversation.add_message(:assistant, content, tool_calls: tool_calls.empty? ? nil : tool_calls)

        break if tool_calls.empty?

        execute_tool_calls(tool_calls)
        persist_session # long tool loops save progressively
      end
    end

    # Keep the conversation within the provider's context budget, stream one
    # completion, then surface truncation / empty-response conditions so the
    # session never silently goes quiet.
    def request_completion(tools)
      manage_context!

      @output.print "\nassistant> "

      result = @provider.chat(@conversation, tools: tools) do |text|
        @output.print text
      end

      @output.puts
      @output.puts

      warn_if_empty_or_truncated(result)
      accumulate_usage(result)
      result
    end

    def accumulate_usage(result)
      usage = result[:usage]
      return unless usage && (usage[:input] || usage[:output])

      @last_usage = usage
      totals = (@session_usage ||= { input: 0, output: 0 })
      totals[:input] += usage[:input].to_i
      totals[:output] += usage[:output].to_i
    end

    # Keep the conversation inside the budget in three escalating steps:
    # summarize old rounds (auto-compact), then blank out old tool results —
    # the only thing that can shrink a single long tool loop, where round
    # trimming and compaction have nothing to drop — and finally trim whole
    # rounds as the last resort.
    def manage_context!
      budget = @provider.context_budget_tokens
      return unless budget

      auto_compact_if_needed(budget)

      elided = @conversation.elide_old_tool_results!(max_tokens: budget)
      @output.puts "[i] Removed #{elided} old tool result(s) to stay within the context limit." if elided.positive?

      removed = @conversation.trim_to_budget!(max_tokens: budget)
      @output.puts "[i] Dropped #{removed} old message(s) to stay within the context limit." if removed.positive?
    end

    def auto_compact_if_needed(budget)
      return unless Yorishiro.configuration.auto_compact_enabled
      return unless @conversation.estimated_tokens > budget * COMPACT_THRESHOLD

      compact_conversation
    end

    def compact_conversation
      @output.puts "[i] Compacting context by summarizing earlier history..."
      compacted = Compactor.new(@provider).compact(@conversation)
      @output.puts "[i] #{compaction_notice(compacted)}"
      compacted
    rescue Yorishiro::ProviderError => e
      @output.puts "[!] Compaction failed (#{e.message}). Old messages will be dropped if needed."
      0
    end

    def compaction_notice(compacted)
      compacted.positive? ? "Summarized and compacted #{compacted} earlier message(s)." : "No old history available to compact."
    end

    def warn_if_empty_or_truncated(result)
      if result[:content].to_s.empty? && result[:tool_calls].empty?
        @output.puts "[!] The model returned an empty response (the context may have been exceeded). " \
                     "Reset with /clear or increase OLLAMA_NUM_CTX."
      end

      budget = @provider.context_budget_tokens
      prompt_tokens = result.dig(:meta, :prompt_eval_count)
      return unless budget && prompt_tokens && prompt_tokens >= budget

      @output.puts "[!] The prompt is approaching the context limit (#{prompt_tokens} tokens). " \
                   "Older messages may have been truncated."
    end

    def plan_then_execute
      @output.puts "\n[Plan Mode] Generating plan..."

      # Expose the read-only tools plus a dedicated exit_plan_mode tool the model
      # calls to signal the plan is ready. Without it the loop can only end on an
      # empty tool_calls response, so a model that keeps reading never terminates.
      exit_tool = Tools::ExitPlanMode.new
      plan_tools = Yorishiro.configuration.read_only_tool_definitions + [exit_tool.definition]

      loop do
        result = request_completion(plan_tools)

        content = result[:content]
        tool_calls = result[:tool_calls]

        @conversation.add_message(:assistant, content, tool_calls: tool_calls.empty? ? nil : tool_calls)

        break if tool_calls.empty?

        # The model signalled the plan is complete: present it and leave the loop.
        exit_call = tool_calls.find { |tc| tc[:name] == exit_tool.name }
        if exit_call
          present_plan(exit_call, exit_tool)
          skip_sibling_tool_calls(tool_calls, exit_call)
          break
        end

        execute_read_only_tool_calls(tool_calls)
        persist_session # long tool loops save progressively
      end

      answer = Reline.readline("Execute this plan? [y/n]: ", false)

      if answer&.strip&.downcase == "y"
        @output.puts "Executing plan..."
        @conversation.add_message(:user, "Please execute the plan you just described.")
        agent_loop
      else
        @output.puts "Plan execution cancelled."
      end
    end

    # Run plan-mode read-only tool calls inline (no permission prompt).
    # before/after hooks still apply, so a policy denial is enforced in
    # plan mode too. Only the read-only tool definitions are offered in
    # plan mode, but the model can still name any registered tool — so a
    # non-read-only call must be refused here, or it would run without
    # the permission prompt the normal loop enforces.
    def execute_read_only_tool_calls(tool_calls)
      tool_calls.each do |tc|
        tool = Yorishiro.configuration.find_tool(tc[:name])
        unless tool
          @conversation.add_tool_result(tool_call_id: tc[:id], content: "Error: Unknown tool '#{tc[:name]}'")
          next
        end

        unless tool.read_only?
          @output.puts "[Plan Mode] Blocked non-read-only tool: #{tc[:name]}"
          @conversation.add_tool_result(
            tool_call_id: tc[:id],
            content: "Error: '#{tc[:name]}' is not available in plan mode — only read-only tools can be used " \
                     "while planning. Include this step in the plan and call exit_plan_mode when it is ready."
          )
          next
        end

        next if denied_by_hook?(tc)

        run_tool(tool, tc)
      end
    end

    # Tool calls issued in the same response as exit_plan_mode are not
    # executed — the plan is already final — but each still needs a tool
    # result: an assistant tool_call left unanswered makes Anthropic/OpenAI
    # reject the follow-up request after the user approves the plan.
    def skip_sibling_tool_calls(tool_calls, exit_call)
      tool_calls.each do |tc|
        next if tc[:id] == exit_call[:id]

        @conversation.add_tool_result(
          tool_call_id: tc[:id],
          content: "Skipped: exit_plan_mode was called in the same response, so this tool was not executed. " \
                   "Run it again after the plan is approved if the result is still needed."
        )
      end
    end

    # Show the plan the model passed to exit_plan_mode and record a tool result
    # for the call — required so the assistant tool_call is never left dangling
    # (the follow-up agent_loop after "y" would otherwise send an unpaired
    # tool_call, which Anthropic/OpenAI reject).
    def present_plan(exit_call, exit_tool)
      @output.puts "\n[Plan]\n#{exit_tool.execute(**symbolize_keys(exit_call[:arguments] || {}))}"
      @conversation.add_tool_result(tool_call_id: exit_call[:id], content: "Plan presented to the user for approval.")
    end

    def execute_tool_calls(tool_calls)
      tool_calls.each do |tc|
        tool = Yorishiro.configuration.find_tool(tc[:name])

        unless tool
          @output.puts "[Tool] Unknown tool: #{tc[:name]}"
          @conversation.add_tool_result(tool_call_id: tc[:id], content: "Error: Unknown tool '#{tc[:name]}'")
          next
        end

        next if denied_by_hook?(tc)

        permission = tool.permission_check(tc[:arguments])

        if permission == :ask
          result = ask_permission(tool, tc)
          unless result == :allowed
            @conversation.add_tool_result(tool_call_id: tc[:id], content: "Permission denied by user.")
            next
          end
        end

        run_tool(tool, tc)
      end
    end

    # before_tool_use hooks fire ahead of the permission prompt (like
    # Claude Code's PreToolUse) so a policy denial never asks the user.
    # The denial is returned to the LLM as the tool result so it can
    # change course.
    def denied_by_hook?(tool_call)
      denial = Yorishiro.configuration.hooks.run_before_tool_use(tool_call[:name], tool_call[:arguments])
      return false unless denial

      @output.puts "[Hook] Denied: #{tool_call[:name]} (#{denial.reason})"
      @conversation.add_tool_result(tool_call_id: tool_call[:id], content: "Tool call denied by hook: #{denial.reason}")
      true
    end

    def run_tool(tool, tool_call)
      @output.puts "[Tool] Executing: #{tool_call[:name]}(#{format_args(tool_call[:arguments])})"
      output = tool.execute(**symbolize_keys(tool_call[:arguments]))
      @output.puts "[Tool] Result: #{truncate(output, 200)}"
      @conversation.add_tool_result(tool_call_id: tool_call[:id], content: cap_tool_result(output))
      run_after_hooks(tool_call, output) # hooks (e.g. audit logs) see the full output
    rescue StandardError => e
      error_msg = "Error: #{e.message}"
      @output.puts "[Tool] #{error_msg}"
      @conversation.add_tool_result(tool_call_id: tool_call[:id], content: error_msg)
    end

    def cap_tool_result(output)
      ToolResultCap.cap(output, budget: @provider&.context_budget_tokens)
    end

    def max_tool_result_chars
      ToolResultCap.max_chars(@provider&.context_budget_tokens)
    end

    # after hooks are observational: a failure is warned about but never
    # alters the already-recorded tool result.
    def run_after_hooks(tool_call, output)
      Yorishiro.configuration.hooks.run_after_tool_use(tool_call[:name], tool_call[:arguments], output)
    rescue StandardError => e
      @output.puts "[!] after_tool_use hook error: #{e.message}"
    end

    def ask_permission(tool, tool_call)
      @output.puts
      @output.puts "[Permission] #{tool.name}"

      preview = tool_preview(tool, tool_call[:arguments])
      preview ? @output.puts(preview) : print_arguments(tool_call[:arguments])

      answer = Reline.readline("[y] Allow once  [a] Always allow  [n] Deny: ", false)&.strip&.downcase

      case answer
      when "y"
        :allowed
      when "a"
        tool.session_allow!(tool_call[:arguments][:command] || tool_call[:arguments]["command"]) if tool.respond_to?(:session_allow!)
        :allowed
      else
        :denied
      end
    end

    def resume_from_options!
      resumed_id = if @cli_opts[:continue]
                     session_resume.continue_latest
                   elsif @cli_opts[:resume] == :pick
                     session_resume.pick
                   elsif @cli_opts[:resume]
                     session_resume.resume_by_id(@cli_opts[:resume])
                   end
      @session_id = resumed_id if resumed_id
    end

    def choose_and_resume_session
      resumed_id = session_resume.pick
      @session_id = resumed_id if resumed_id
    end

    def session_resume
      SessionResume.new(
        store: @session_store,
        conversation: @conversation,
        output: @output,
        current_target: "#{Yorishiro.configuration.provider_name}:#{@provider.model_name}"
      )
    end

    def persist_session
      return if @session_store.nil? || @conversation.nil? || @conversation.messages.empty?

      @session_id = @session_store.save(
        id: @session_id,
        messages: @conversation.serializable_messages,
        provider: Yorishiro.configuration.provider_name,
        model: @provider.model_name
      ) || @session_id
    end

    # A failing preview must never break the permission flow — fall back
    # to the plain argument dump. Colors only when the output is a TTY.
    def tool_preview(tool, arguments)
      return nil unless arguments

      preview = tool.preview(arguments)
      return nil unless preview

      @output.respond_to?(:tty?) && @output.tty? ? Diff.colorize(preview) : preview
    rescue StandardError
      nil
    end

    def print_arguments(arguments)
      arguments&.each do |key, value|
        str = value.to_s
        if str.length > 80 || str.include?("\n")
          @output.puts "  #{key}:"
          preview = truncate(str, 500)
          preview.each_line { |line| @output.puts "    #{line}" }
        else
          @output.puts "  #{key}: #{str}"
        end
      end
    end

    def handle_slash_command(input)
      command, *args = input.split(/\s+/)

      case command
      when "/plan"
        @plan_mode = !@plan_mode
        @output.puts "Plan mode: #{@plan_mode ? "ON" : "OFF"}"
      when "/clear"
        clear_conversation!
      when "/compact"
        compact_conversation
      when "/resume"
        choose_and_resume_session
      when "/tools"
        list_tools
      when "/skills"
        list_skills
      when "/usage"
        print_usage
      when "/model"
        switch_model(args)
      when "/exit", "/quit"
        @output.puts "Goodbye!"
        exit
      when "/help"
        print_help
      else
        handle_skill_command(command, args)
      end
    end

    def handle_skill_command(command, args)
      skill = Yorishiro.configuration.skills.find { |s| "/#{s.name}" == command }
      unless skill
        @output.puts "Unknown command: #{command}. Type /help for available commands."
        return
      end

      result = skill.execute({ conversation: @conversation, args: args })
      case result
      when Yorishiro::Skill::Prompt
        process_user_input(result.text) # inject prompt -> plan/agent loop
      when String
        @output.puts result
      end
    end

    # /model            -> list current + available models
    # /model <name>     -> switch model within the current provider
    # /model <prov> <m> -> switch provider and model
    def switch_model(args)
      case args.length
      when 0
        show_model_options
      when 1
        apply_model_switch(provider: Yorishiro.configuration.provider_name, model: args[0])
      else
        apply_model_switch(provider: args[0].to_sym, model: args[1])
      end
    end

    def apply_model_switch(provider:, model:)
      config = Yorishiro.configuration
      config.switch!(provider: provider, model: model, api_key: resolve_api_key(provider))
      @provider = Provider.build(config)
      attach_tools! # re-point subagent tools at the new provider
      @output.puts "Now using #{config.provider_name}:#{@provider.model_name}"
    rescue Yorishiro::ConfigurationError => e
      @output.puts "[!] #{e.message}"
    end

    # Reuse the existing key when the provider is unchanged; otherwise read it
    # from the provider's conventional env var (nil for Ollama, which needs none).
    def resolve_api_key(provider)
      config = Yorishiro.configuration
      return config.api_key if provider == config.provider_name

      env = API_KEY_ENV[provider]
      env && ENV.fetch(env, nil)
    end

    def show_model_options
      config = Yorishiro.configuration
      @output.puts "Current: #{config.provider_name}:#{@provider.model_name}"

      models = Provider.for(config.provider_name).supported_models
      if models.empty?
        @output.puts "  (no model list available for #{config.provider_name})"
      else
        models.each { |m| @output.puts "  #{m}" }
      end
      @output.puts "Usage: /model <name>  |  /model <provider> <name>"
    rescue Yorishiro::ProviderNotImplementedError => e
      @output.puts "[!] #{e.message}"
    end

    def clear_conversation!
      @conversation = Conversation.new(system_prompt: Yorishiro.configuration.system_prompt_text)
      @session_id = nil # the old session file stays on disk for /resume
      @session_usage = { input: 0, output: 0 }
      @last_usage = nil
      @output.puts "Conversation cleared. Started a new session."
    end

    def print_usage
      totals = (@session_usage ||= { input: 0, output: 0 })
      unless @last_usage || totals[:input].positive? || totals[:output].positive?
        estimate = @conversation&.estimated_tokens
        note = "No token usage reported yet by this provider."
        note += " Estimated conversation size: ~#{estimate} tokens." if estimate
        @output.puts note
        return
      end

      if @last_usage
        input = @last_usage[:input].to_i
        output = @last_usage[:output].to_i
        @output.puts "Token usage (last turn): prompt #{input}, completion #{output}, total #{input + output}"
      end
      @output.puts "Token usage (session):   prompt #{totals[:input]}, completion #{totals[:output]}, " \
                   "total #{totals[:input] + totals[:output]}"

      budget = @provider.context_budget_tokens
      return unless budget && @last_usage && @last_usage[:input]

      input = @last_usage[:input].to_i
      @output.puts "Context: #{input} / #{budget} tokens (#{(input * 100.0 / budget).round}%)"
    end

    def list_tools
      tools = Yorishiro.configuration.allowed_tools
      if tools.empty?
        @output.puts "No tools registered."
      else
        tools.each { |t| @output.puts "  #{t.name} - #{t.description}" }
      end
    end

    def list_skills
      skills = Yorishiro.configuration.skills
      if skills.empty?
        @output.puts "No skills registered."
      else
        skills.each { |s| @output.puts "  /#{s.name} - #{s.description}" }
      end
    end

    def print_help
      @output.puts <<~HELP
        Commands:
          /plan     - Toggle plan mode
          /clear    - Clear conversation
          /compact  - Summarize and compact conversation history
          /resume   - List and resume a saved session
          /tools    - List available tools
          /skills   - List available skills
          /usage    - Show token usage
          /model    - Switch provider/model (list when no args)
          /exit     - Exit yorishiro
          /help     - Show this help
      HELP
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
