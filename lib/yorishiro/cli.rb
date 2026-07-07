# frozen_string_literal: true

require "reline"
require "optparse"

module Yorishiro
  class CLI
    # Fraction of the context budget at which auto-compaction kicks in.
    COMPACT_THRESHOLD = 0.8

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

      config.use(provider: @cli_opts[:provider]) if @cli_opts[:provider]
      config.instance_variable_set(:@model, @cli_opts[:model]) if @cli_opts[:model]

      @provider = Provider.build(config)
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

        if input.strip.start_with?("/")
          handle_slash_command(input.strip)
          next
        end

        begin
          process_user_input(input)
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
      result
    end

    # Auto-compact (summarize old history) when nearing the budget, then apply a
    # mechanical trim as a fallback for anything still over the limit (e.g. a
    # single oversized round, or when summarization failed).
    def manage_context!
      budget = @provider.context_budget_tokens
      return unless budget

      auto_compact_if_needed(budget)

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

      read_only_tools = Yorishiro.configuration.read_only_tool_definitions

      loop do
        result = request_completion(read_only_tools)

        content = result[:content]
        tool_calls = result[:tool_calls]

        @conversation.add_message(:assistant, content, tool_calls: tool_calls.empty? ? nil : tool_calls)

        break if tool_calls.empty?

        # read-only ツールはパーミッション不要で即実行
        tool_calls.each do |tc|
          tool = Yorishiro.configuration.find_tool(tc[:name])
          unless tool
            @conversation.add_tool_result(tool_call_id: tc[:id], content: "Error: Unknown tool '#{tc[:name]}'")
            next
          end

          @output.puts "[Tool] Executing: #{tc[:name]}(#{format_args(tc[:arguments])})"
          begin
            output = tool.execute(**symbolize_keys(tc[:arguments]))
            @output.puts "[Tool] Result: #{truncate(output, 200)}"
            @conversation.add_tool_result(tool_call_id: tc[:id], content: output)
          rescue StandardError => e
            error_msg = "Error: #{e.message}"
            @output.puts "[Tool] #{error_msg}"
            @conversation.add_tool_result(tool_call_id: tc[:id], content: error_msg)
          end
        end

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

    def execute_tool_calls(tool_calls)
      tool_calls.each do |tc|
        tool = Yorishiro.configuration.find_tool(tc[:name])

        unless tool
          @output.puts "[Tool] Unknown tool: #{tc[:name]}"
          @conversation.add_tool_result(tool_call_id: tc[:id], content: "Error: Unknown tool '#{tc[:name]}'")
          next
        end

        permission = tool.permission_check(tc[:arguments])

        if permission == :ask
          result = ask_permission(tool, tc)
          unless result == :allowed
            @conversation.add_tool_result(tool_call_id: tc[:id], content: "Permission denied by user.")
            next
          end
        end

        @output.puts "[Tool] Executing: #{tc[:name]}(#{format_args(tc[:arguments])})"

        begin
          output = tool.execute(**symbolize_keys(tc[:arguments]))
          @output.puts "[Tool] Result: #{truncate(output, 200)}"
          @conversation.add_tool_result(tool_call_id: tc[:id], content: output)
        rescue StandardError => e
          error_msg = "Error: #{e.message}"
          @output.puts "[Tool] #{error_msg}"
          @conversation.add_tool_result(tool_call_id: tc[:id], content: error_msg)
        end
      end
    end

    def ask_permission(tool, tool_call)
      @output.puts
      @output.puts "[Permission] #{tool.name}"
      tool_call[:arguments]&.each do |key, value|
        str = value.to_s
        if str.length > 80 || str.include?("\n")
          @output.puts "  #{key}:"
          preview = truncate(str, 500)
          preview.each_line { |line| @output.puts "    #{line}" }
        else
          @output.puts "  #{key}: #{str}"
        end
      end
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
      when "/exit", "/quit"
        @output.puts "Goodbye!"
        exit
      when "/help"
        print_help
      else
        skill = Yorishiro.configuration.skills.find { |s| "/#{s.name}" == command }
        if skill
          result = skill.execute({ conversation: @conversation, args: args })
          case result
          when Yorishiro::Skill::Prompt
            process_user_input(result.text) # inject prompt -> plan/agent loop
          when String
            @output.puts result
          end
        else
          @output.puts "Unknown command: #{command}. Type /help for available commands."
        end
      end
    end

    def clear_conversation!
      @conversation = Conversation.new(system_prompt: Yorishiro.configuration.system_prompt_text)
      @session_id = nil # the old session file stays on disk for /resume
      @output.puts "Conversation cleared. Started a new session."
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
