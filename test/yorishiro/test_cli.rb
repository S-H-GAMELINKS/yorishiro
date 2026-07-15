# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestCLI < Minitest::Test
  class FakeTool < Yorishiro::Tool
    def name = "write_file"
    def description = "Write a file"
    def parameters = { type: "object" }
  end

  class PreviewTool < FakeTool
    def preview(_arguments) = "@@ -1,1 +1,1 @@\n-old line\n+new line"
  end

  class RaisingPreviewTool < FakeTool
    def preview(_arguments) = raise "preview boom"
  end

  class RecordingTool < Yorishiro::Tool
    attr_reader :executed

    def initialize
      super
      @executed = false
    end

    def name = "recording_tool"
    def description = "records executions"
    def parameters = { type: "object" }
    def permission_check(_arguments) = :ask

    def execute(**_params)
      @executed = true
      "recorded ok"
    end
  end

  class ReadOnlyRecordingTool < RecordingTool
    def name = "read_only_recording_tool"
    def read_only? = true
  end

  class FakeProvider
    attr_accessor :budget
    attr_reader :chat_calls

    def initialize(budget: nil)
      @budget = budget
      @chat_calls = 0
    end

    def context_budget_tokens = @budget

    def model_name = "fake-model"

    def chat(_conversation, tools: [], &) # rubocop:disable Lint/UnusedMethodArgument
      @chat_calls += 1
      { content: "SUMMARY", tool_calls: [], meta: {} }
    end
  end

  class ScriptedProvider
    def initialize(*results)
      @results = results
    end

    def context_budget_tokens = nil

    def model_name = "scripted-model"

    def chat(_conversation, tools: [], &) # rubocop:disable Lint/UnusedMethodArgument
      @results.shift || { content: "done", tool_calls: [] }
    end
  end

  class RaisingProvider < Yorishiro::Provider::Base
    def self.supported_models = ["x"]
    def chat(*_args, **_kwargs) = raise Yorishiro::ProviderError, "boom"

    private

    def default_model = "x"
  end

  class PrintingSkill < Yorishiro::Skill
    def name = "hello"
    def description = "print hello"
    def execute(_context) = "printed output"
  end

  class PromptSkill < Yorishiro::Skill
    def name = "review"
    def description = "review via LLM"
    def execute(_context) = prompt("please review")
  end

  class RaisingSkill < Yorishiro::Skill
    def name = "boom"
    def description = "always raises"
    def execute(_context) = raise "skill exploded"
  end

  def setup
    @output = StringIO.new
    @cli = Yorishiro::CLI.new
    @cli.instance_variable_set(:@output, @output)
  end

  def test_ask_permission_short_args
    tool = FakeTool.new
    tool_call = { arguments: { "path" => "test.rb", "mode" => "write" } }

    simulate_input("y") do
      result = @cli.send(:ask_permission, tool, tool_call)
      assert_equal :allowed, result
    end

    output = @output.string
    assert_includes output, "[Permission] write_file"
    assert_includes output, "  path: test.rb"
    assert_includes output, "  mode: write"
  end

  def test_ask_permission_long_content_multiline
    tool = FakeTool.new
    content = "puts \"Hello, World!\"\nputs \"This is a test.\"\nputs \"Line three.\""
    tool_call = { arguments: { "path" => "test.rb", "content" => content } }

    simulate_input("y") do
      @cli.send(:ask_permission, tool, tool_call)
    end

    output = @output.string
    assert_includes output, "[Permission] write_file"
    assert_includes output, "  path: test.rb"
    assert_includes output, "  content:"
    assert_includes output, "    puts \"Hello, World!\""
    assert_includes output, "    puts \"This is a test.\""
  end

  def test_ask_permission_long_single_line_content
    tool = FakeTool.new
    content = "a" * 100
    tool_call = { arguments: { "path" => "test.rb", "content" => content } }

    simulate_input("y") do
      @cli.send(:ask_permission, tool, tool_call)
    end

    output = @output.string
    assert_includes output, "  content:"
    assert_includes output, "    #{"a" * 100}"
  end

  def test_ask_permission_truncates_very_long_content
    tool = FakeTool.new
    content = "x" * 600
    tool_call = { arguments: { "content" => content } }

    simulate_input("y") do
      @cli.send(:ask_permission, tool, tool_call)
    end

    output = @output.string
    assert_includes output, "  content:"
    assert_includes output, "x" * 500
    assert_includes output, "..."
  end

  def test_ask_permission_shows_preview_instead_of_arguments
    tool = PreviewTool.new
    tool_call = { arguments: { "path" => "test.rb", "content" => "new line\n" } }

    simulate_input("y") do
      result = @cli.send(:ask_permission, tool, tool_call)
      assert_equal :allowed, result
    end

    output = @output.string
    assert_includes output, "-old line"
    assert_includes output, "+new line"
    refute_includes output, "  path: test.rb" # argument dump replaced by the preview
    refute_includes output, "\e[" # StringIO is not a tty, so no ANSI colors
  end

  def test_ask_permission_falls_back_when_preview_raises
    tool = RaisingPreviewTool.new
    tool_call = { arguments: { "path" => "test.rb" } }

    simulate_input("y") do
      result = @cli.send(:ask_permission, tool, tool_call)
      assert_equal :allowed, result
    end

    output = @output.string
    assert_includes output, "  path: test.rb"
    refute_includes output, "preview boom"
  end

  def test_ask_permission_deny
    tool = FakeTool.new
    tool_call = { arguments: { "path" => "test.rb" } }

    simulate_input("n") do
      result = @cli.send(:ask_permission, tool, tool_call)
      assert_equal :denied, result
    end
  end

  def test_ask_permission_nil_arguments
    tool = FakeTool.new
    tool_call = { arguments: nil }

    simulate_input("y") do
      result = @cli.send(:ask_permission, tool, tool_call)
      assert_equal :allowed, result
    end

    output = @output.string
    assert_includes output, "[Permission] write_file"
  end

  def test_warn_on_empty_response
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: 6144))
    @cli.send(:warn_if_empty_or_truncated, { content: "", tool_calls: [], meta: {} })
    assert_includes @output.string, "empty response"
  end

  def test_warn_on_prompt_near_context
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: 100))
    @cli.send(:warn_if_empty_or_truncated, { content: "ok", tool_calls: [], meta: { prompt_eval_count: 150 } })
    assert_includes @output.string, "approaching the context limit"
  end

  def test_no_warning_on_normal_response
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: 6144))
    @cli.send(:warn_if_empty_or_truncated, { content: "hello", tool_calls: [], meta: { prompt_eval_count: 10 } })
    refute_includes @output.string, "[!]"
  end

  def test_accumulate_and_print_usage
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: 1000))
    @cli.send(:accumulate_usage, { content: "a", tool_calls: [], usage: { input: 30, output: 5 } })
    @cli.send(:accumulate_usage, { content: "b", tool_calls: [], usage: { input: 12, output: 8 } })

    @cli.send(:print_usage)
    output = @output.string
    assert_includes output, "prompt 12, completion 8, total 20"   # last turn
    assert_includes output, "prompt 42, completion 13, total 55"  # session
    assert_includes output, "Context: 12 / 1000 tokens"
  end

  def test_print_usage_without_data_falls_back_to_estimate
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: nil))
    @cli.instance_variable_set(:@conversation, Yorishiro::Conversation.new)

    @cli.send(:print_usage)
    assert_includes @output.string, "No token usage reported"
  end

  def test_clear_conversation_resets_usage
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: nil))
    @cli.send(:accumulate_usage, { content: "a", tool_calls: [], usage: { input: 30, output: 5 } })

    @cli.send(:clear_conversation!)

    assert_equal({ input: 0, output: 0 }, @cli.instance_variable_get(:@session_usage))
    assert_nil @cli.instance_variable_get(:@last_usage)
  end

  def test_manage_context_trims_when_compaction_disabled
    Yorishiro.reset!
    Yorishiro.configuration.auto_compact(false)

    conv = Yorishiro::Conversation.new
    6.times do
      conv.add_message(:user, "u" * 400)
      conv.add_message(:assistant, "a" * 400)
    end
    provider = FakeProvider.new(budget: 200)
    @cli.instance_variable_set(:@conversation, conv)
    @cli.instance_variable_set(:@provider, provider)

    @cli.send(:manage_context!)

    assert_includes @output.string, "Dropped"
    assert_equal 0, provider.chat_calls # compaction disabled → no summarization call
  ensure
    Yorishiro.reset!
  end

  def test_manage_context_auto_compacts
    Yorishiro.reset!
    Yorishiro.configuration.auto_compact(true)

    conv = Yorishiro::Conversation.new
    4.times do |i|
      conv.add_message(:user, "old question #{i} " * 40)
      conv.add_message(:assistant, "old answer #{i} " * 40)
    end
    conv.add_message(:user, "hi")
    conv.add_message(:assistant, "ok")
    conv.add_message(:user, "thanks")
    conv.add_message(:assistant, "yw")

    provider = FakeProvider.new(budget: 500)
    @cli.instance_variable_set(:@conversation, conv)
    @cli.instance_variable_set(:@provider, provider)

    @cli.send(:manage_context!)

    assert_equal 1, provider.chat_calls
    assert_includes @output.string, "Summarized"
    assert_includes conv.messages[0][:content], "Summary of earlier conversation"
    assert_equal "yw", conv.messages.last[:content]
  ensure
    Yorishiro.reset!
  end

  def test_manage_context_noop_without_budget
    conv = Yorishiro::Conversation.new
    conv.add_message(:user, "hi")
    @cli.instance_variable_set(:@conversation, conv)
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: nil))

    @cli.send(:manage_context!)
    assert_equal "", @output.string
  end

  def test_repl_loop_survives_provider_error
    @cli.instance_variable_set(:@provider, RaisingProvider.new(api_key: "x"))
    @cli.instance_variable_set(:@conversation, Yorishiro::Conversation.new)
    @cli.instance_variable_set(:@plan_mode, false)

    inputs = ["trigger an error", nil]
    reader = -> { inputs.shift }
    @cli.stub(:read_input, reader) do
      @cli.send(:repl_loop)
    end

    assert_includes @output.string, "[Error]"
    assert_includes @output.string, "boom"
  end

  def test_repl_loop_survives_skill_error
    Yorishiro.reset!
    Yorishiro.configuration.skill(RaisingSkill.new)
    @cli.instance_variable_set(:@conversation, Yorishiro::Conversation.new)
    @cli.instance_variable_set(:@plan_mode, false)

    inputs = ["/boom", "still alive", nil]
    reader = -> { inputs.shift }
    @cli.instance_variable_set(:@provider, FakeProvider.new)
    @cli.stub(:read_input, reader) do
      @cli.send(:repl_loop)
    end

    assert_includes @output.string, "[Error] RuntimeError: skill exploded"
    # The next input was still processed — the REPL survived the skill error.
    conv = @cli.instance_variable_get(:@conversation)
    assert_includes conv.messages.map { |m| m[:content] }, "still alive"
    assert_equal :assistant, conv.last_role
  ensure
    Yorishiro.reset!
  end

  def test_repl_loop_survives_provider_error_from_prompt_skill
    Yorishiro.reset!
    Yorishiro.configuration.skill(PromptSkill.new)
    @cli.instance_variable_set(:@conversation, Yorishiro::Conversation.new)
    @cli.instance_variable_set(:@plan_mode, false)
    @cli.instance_variable_set(:@provider, RaisingProvider.new(api_key: "x"))

    inputs = ["/review", nil]
    reader = -> { inputs.shift }
    @cli.stub(:read_input, reader) do
      @cli.send(:repl_loop) # must not raise
    end

    assert_includes @output.string, "[Error] boom"
  ensure
    Yorishiro.reset!
  end

  def test_process_user_input_persists_session
    Yorishiro.reset!
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      setup_session_cli(store)

      @cli.send(:process_user_input, "hello world")

      session = store.latest
      refute_nil session
      assert_equal "hello world", session[:title]
      assert_equal "fake-model", session[:model]
      assert_equal 2, session[:messages].length # user + assistant reply
    end
  ensure
    Yorishiro.reset!
  end

  def test_before_hook_denies_tool_and_skips_permission_prompt
    Yorishiro.reset!
    tool = RecordingTool.new
    Yorishiro.configuration.allow_tool(tool)
    Yorishiro.configuration.on(:before_tool_use) do |name, _args|
      Yorishiro::Hooks::Denial.new("policy") if name == "recording_tool"
    end
    conv = Yorishiro::Conversation.new
    @cli.instance_variable_set(:@conversation, conv)

    prompt_called = false
    fake_readline = lambda { |*_args|
      prompt_called = true
      "y"
    }
    Reline.stub(:readline, fake_readline) do
      @cli.send(:execute_tool_calls, [{ id: "1", name: "recording_tool", arguments: {} }])
    end

    refute tool.executed
    refute prompt_called # denied before the permission prompt
    assert_includes conv.messages.last[:content], "denied by hook: policy"
    assert_includes @output.string, "[Hook] Denied: recording_tool (policy)"
  ensure
    Yorishiro.reset!
  end

  def test_persist_session_skips_empty_conversation
    Yorishiro.reset!
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      setup_session_cli(store)

      @cli.send(:persist_session)

      assert_nil store.latest
    end
  ensure
    Yorishiro.reset!
  end

  def test_before_hook_exception_denies_tool
    Yorishiro.reset!
    tool = RecordingTool.new
    Yorishiro.configuration.allow_tool(tool)
    Yorishiro.configuration.on(:before_tool_use) { raise "guard broke" }
    conv = Yorishiro::Conversation.new
    @cli.instance_variable_set(:@conversation, conv)

    @cli.send(:execute_tool_calls, [{ id: "1", name: "recording_tool", arguments: {} }])

    refute tool.executed
    assert_includes conv.messages.last[:content], "guard broke"
  ensure
    Yorishiro.reset!
  end

  def test_clear_starts_a_new_session_file
    Yorishiro.reset!
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      setup_session_cli(store)

      @cli.send(:process_user_input, "first session")
      @cli.send(:handle_slash_command, "/clear")
      @cli.send(:process_user_input, "second session")

      assert_equal 2, store.list.length
      assert_includes @output.string, "Started a new session"
    end
  ensure
    Yorishiro.reset!
  end

  def test_after_hook_receives_result
    Yorishiro.reset!
    tool = RecordingTool.new
    Yorishiro.configuration.allow_tool(tool)
    received = nil
    Yorishiro.configuration.on(:after_tool_use) { |name, args, result| received = [name, args, result] }
    conv = Yorishiro::Conversation.new
    @cli.instance_variable_set(:@conversation, conv)

    simulate_input("y") do
      @cli.send(:execute_tool_calls, [{ id: "1", name: "recording_tool", arguments: { "a" => 1 } }])
    end

    assert tool.executed
    assert_equal ["recording_tool", { "a" => 1 }, "recorded ok"], received
  ensure
    Yorishiro.reset!
  end

  def test_resume_slash_command_restores_conversation
    Yorishiro.reset!
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      saved_id = store.save(
        id: nil,
        messages: [{ "role" => "user", "content" => "remember me" }, { "role" => "assistant", "content" => "noted" }],
        provider: :ollama,
        model: "gemma4:12b"
      )
      setup_session_cli(store)

      simulate_input("1") do
        @cli.send(:handle_slash_command, "/resume")
      end

      conv = @cli.instance_variable_get(:@conversation)
      assert_equal 2, conv.length
      assert_equal "remember me", conv.messages.first[:content]
      assert_equal saved_id, @cli.instance_variable_get(:@session_id)
      assert_includes @output.string, "Resumed session #{saved_id}"
      assert_includes @output.string, "recorded with ollama:gemma4:12b" # model mismatch notice
    end
  ensure
    Yorishiro.reset!
  end

  def test_after_hook_error_warns_but_keeps_result
    Yorishiro.reset!
    tool = RecordingTool.new
    Yorishiro.configuration.allow_tool(tool)
    Yorishiro.configuration.on(:after_tool_use) { raise "observer broke" }
    conv = Yorishiro::Conversation.new
    @cli.instance_variable_set(:@conversation, conv)

    simulate_input("y") do
      @cli.send(:execute_tool_calls, [{ id: "1", name: "recording_tool", arguments: {} }])
    end

    assert_equal "recorded ok", conv.messages.last[:content] # result kept, no duplicate error result
    assert_includes @output.string, "after_tool_use hook error: observer broke"
  ensure
    Yorishiro.reset!
  end

  def test_resume_picker_cancels_on_invalid_choice
    Yorishiro.reset!
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      store.save(id: nil, messages: [{ "role" => "user", "content" => "hi" }], provider: :ollama, model: "m")
      setup_session_cli(store)

      simulate_input("") do
        @cli.send(:handle_slash_command, "/resume")
      end

      assert_equal 0, @cli.instance_variable_get(:@conversation).length
      assert_includes @output.string, "Cancelled."
    end
  ensure
    Yorishiro.reset!
  end

  def test_persist_session_runs_even_when_provider_raises
    Yorishiro.reset!
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      setup_session_cli(store)
      @cli.instance_variable_set(:@provider, RaisingProvider.new(api_key: "x"))

      assert_raises(Yorishiro::ProviderError) { @cli.send(:process_user_input, "will fail") }

      session = store.latest
      refute_nil session # the user message survived the crash via ensure
      assert_equal "will fail", session[:title]
    end
  ensure
    Yorishiro.reset!
  end

  def test_user_prompt_submit_denial_blocks_message
    Yorishiro.reset!
    Yorishiro.configuration.on(:user_prompt_submit) { |input| Yorishiro::Hooks::Denial.new("secret") if input.include?("password") }
    conv = Yorishiro::Conversation.new
    provider = FakeProvider.new(budget: nil)
    @cli.instance_variable_set(:@conversation, conv)
    @cli.instance_variable_set(:@provider, provider)
    @cli.instance_variable_set(:@plan_mode, false)

    @cli.send(:process_user_input, "my password is hunter2")

    assert_equal 0, conv.length
    assert_equal 0, provider.chat_calls
    assert_includes @output.string, "[Hook] Prompt blocked: secret"
  ensure
    Yorishiro.reset!
  end

  def test_run_tool_caps_oversized_output
    Yorishiro.reset!
    big_tool = Class.new(Yorishiro::Tool) do
      def name = "big_tool"
      def description = "returns a huge output"
      def parameters = { type: "object" }
      def execute(**_params) = "y" * 5_000
    end.new
    conv = Yorishiro::Conversation.new
    @cli.instance_variable_set(:@conversation, conv)
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: 100)) # floor: MIN_TOOL_RESULT_CHARS

    @cli.send(:run_tool, big_tool, { id: "1", name: "big_tool", arguments: {} })

    content = conv.messages.last[:content]
    assert_operator content.length, :<, 2_500
    assert_includes content, "tool output truncated"
    assert_includes content, "5000 characters"
  ensure
    Yorishiro.reset!
  end

  def test_run_tool_leaves_small_output_untouched
    Yorishiro.reset!
    conv = Yorishiro::Conversation.new
    @cli.instance_variable_set(:@conversation, conv)
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: 100))
    tool = RecordingTool.new

    simulate_input("y") do
      @cli.send(:run_tool, tool, { id: "1", name: "recording_tool", arguments: {} })
    end

    assert_equal "recorded ok", conv.messages.last[:content]
  ensure
    Yorishiro.reset!
  end

  def test_max_tool_result_chars_scales_with_budget
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: 8000))
    assert_equal 8000, @cli.send(:max_tool_result_chars) # 8000 tokens * 4 chars/token / 4

    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: nil))
    assert_equal 30_000, @cli.send(:max_tool_result_chars)
  end

  def test_manage_context_elides_tool_results_within_a_single_round
    Yorishiro.reset!
    Yorishiro.configuration.auto_compact(false)
    conv = Yorishiro::Conversation.new
    conv.add_message(:user, "implement the feature")
    tool_calls = (0...4).map { |i| { id: "tc_#{i}", name: "read_file", arguments: {} } }
    conv.add_message(:assistant, "", tool_calls: tool_calls)
    4.times { |i| conv.add_tool_result(tool_call_id: "tc_#{i}", content: "r#{i} #{"x" * 800}") }
    @cli.instance_variable_set(:@conversation, conv)
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: 400))

    @cli.send(:manage_context!)

    assert_includes @output.string, "Removed 2 old tool result(s)"
    assert_equal 6, conv.length # no rounds were dropped — space was freed in place
    assert_equal Yorishiro::Conversation::ELIDED_TOOL_RESULT, conv.messages[2][:content]
    assert_includes conv.messages[5][:content], "r3" # most recent results kept
  ensure
    Yorishiro.reset!
  end

  def test_attach_tools_hands_provider_and_output_to_attachable_tools
    Yorishiro.reset!
    attachable = Class.new(Yorishiro::Tool) do
      attr_reader :attached_provider, :attached_output

      def name = "attachable"
      def description = "records attach"
      def parameters = { type: "object" }

      def attach(provider:, output:)
        @attached_provider = provider
        @attached_output = output
      end
    end.new
    Yorishiro.configuration.allow_tool(attachable)
    Yorishiro.configuration.allow_tool(FakeTool.new) # no #attach — must be skipped, not crash
    provider = FakeProvider.new
    @cli.instance_variable_set(:@provider, provider)

    @cli.send(:attach_tools!)

    assert_same provider, attachable.attached_provider
    assert_same @output, attachable.attached_output
  ensure
    Yorishiro.reset!
  end

  def test_skill_returning_string_prints_output
    Yorishiro.reset!
    Yorishiro.configuration.skill(PrintingSkill.new)
    @cli.instance_variable_set(:@conversation, Yorishiro::Conversation.new)

    @cli.send(:handle_slash_command, "/hello")

    assert_includes @output.string, "printed output"
  ensure
    Yorishiro.reset!
  end

  def test_skill_returning_prompt_runs_agent_loop
    Yorishiro.reset!
    Yorishiro.configuration.skill(PromptSkill.new)
    conv = Yorishiro::Conversation.new
    provider = FakeProvider.new(budget: nil)
    @cli.instance_variable_set(:@conversation, conv)
    @cli.instance_variable_set(:@provider, provider)
    @cli.instance_variable_set(:@plan_mode, false)

    @cli.send(:handle_slash_command, "/review")

    assert_equal 1, provider.chat_calls # prompt was injected and the LLM ran
    assert_equal "please review", conv.messages.first[:content]
    assert_equal :user, conv.messages.first[:role]
  ensure
    Yorishiro.reset!
  end

  def test_model_command_switches_model
    Yorishiro.reset!
    stub_request(:get, "http://localhost:11434/api/tags")
      .to_return(status: 200, body: '{"models":[{"name":"gemma3:4b"},{"name":"llama3.1"}]}')
    Yorishiro.configuration.use(provider: :ollama, model: "llama3.1")
    @cli.instance_variable_set(:@provider, Yorishiro::Provider.build(Yorishiro.configuration))

    @cli.send(:handle_slash_command, "/model gemma3:4b")

    assert_equal "gemma3:4b", @cli.instance_variable_get(:@provider).model_name
    assert_includes @output.string, "Now using ollama:gemma3:4b"
  ensure
    Yorishiro.reset!
  end

  def test_model_command_lists_options
    Yorishiro.reset!
    stub_request(:get, "http://localhost:11434/api/tags")
      .to_return(status: 200, body: '{"models":[{"name":"gemma3:4b"},{"name":"llama3.1"}]}')
    Yorishiro.configuration.use(provider: :ollama, model: "llama3.1")
    @cli.instance_variable_set(:@provider, Yorishiro::Provider.build(Yorishiro.configuration))

    @cli.send(:handle_slash_command, "/model")

    assert_includes @output.string, "Current: ollama:llama3.1"
    assert_includes @output.string, "gemma3:4b"
  ensure
    Yorishiro.reset!
  end

  def test_model_command_rejects_unknown_model
    Yorishiro.reset!
    stub_request(:get, "http://localhost:11434/api/tags")
      .to_return(status: 200, body: '{"models":[{"name":"llama3.1"}]}')
    Yorishiro.configuration.use(provider: :ollama, model: "llama3.1")
    @cli.instance_variable_set(:@provider, Yorishiro::Provider.build(Yorishiro.configuration))

    @cli.send(:handle_slash_command, "/model nonexistent")

    assert_includes @output.string, "[!]"
    assert_equal "llama3.1", @cli.instance_variable_get(:@provider).model_name # unchanged
  ensure
    Yorishiro.reset!
  end

  def test_provider_option_preserves_rc_api_key_and_model
    Yorishiro.reset!
    config = Yorishiro.configuration
    config.use(provider: :anthropic, api_key: "sk-from-rc", model: "claude-opus-4-8")
    @cli.instance_variable_set(:@cli_opts, { provider: :anthropic })

    @cli.send(:apply_cli_overrides!, config)

    assert_equal "sk-from-rc", config.api_key
    assert_equal "claude-opus-4-8", config.model
  ensure
    Yorishiro.reset!
  end

  def test_provider_option_switches_provider_reading_env_key
    Yorishiro.reset!
    config = Yorishiro.configuration
    config.use(provider: :anthropic, api_key: "sk-anthropic", model: "claude-opus-4-8")
    @cli.instance_variable_set(:@cli_opts, { provider: :open_ai })
    old_key = ENV.fetch("OPENAI_API_KEY", nil)
    ENV["OPENAI_API_KEY"] = "sk-openai"

    @cli.send(:apply_cli_overrides!, config)

    assert_equal :open_ai, config.provider_name
    assert_equal "sk-openai", config.api_key
    assert_nil config.model # the rc model belonged to the old provider
  ensure
    old_key ? ENV["OPENAI_API_KEY"] = old_key : ENV.delete("OPENAI_API_KEY")
    Yorishiro.reset!
  end

  def test_model_option_keeps_provider_and_api_key
    Yorishiro.reset!
    config = Yorishiro.configuration
    config.use(provider: :anthropic, api_key: "sk-from-rc")
    @cli.instance_variable_set(:@cli_opts, { model: "claude-haiku-4-5" })

    @cli.send(:apply_cli_overrides!, config)

    assert_equal :anthropic, config.provider_name
    assert_equal "sk-from-rc", config.api_key
    assert_equal "claude-haiku-4-5", config.model
  ensure
    Yorishiro.reset!
  end

  def test_model_option_rejects_unsupported_model_and_rolls_back
    Yorishiro.reset!
    config = Yorishiro.configuration
    config.use(provider: :anthropic, api_key: "sk-from-rc", model: "claude-opus-4-8")
    @cli.instance_variable_set(:@cli_opts, { model: "bogus-model" })

    assert_raises(Yorishiro::ConfigurationError) { @cli.send(:apply_cli_overrides!, config) }

    assert_equal "claude-opus-4-8", config.model
    assert_equal "sk-from-rc", config.api_key
  ensure
    Yorishiro.reset!
  end

  def test_no_cli_overrides_leaves_configuration_untouched
    Yorishiro.reset!
    config = Yorishiro.configuration
    config.use(provider: :anthropic, api_key: "sk-from-rc", model: "claude-opus-4-8")
    @cli.instance_variable_set(:@cli_opts, {})

    @cli.send(:apply_cli_overrides!, config)

    assert_equal :anthropic, config.provider_name
    assert_equal "sk-from-rc", config.api_key
    assert_equal "claude-opus-4-8", config.model
  ensure
    Yorishiro.reset!
  end

  def test_plan_mode_blocks_non_read_only_tool_without_executing_it
    Yorishiro.reset!
    tool = RecordingTool.new # read_only? is false, permission_check is :ask
    Yorishiro.configuration.allow_tool(tool)
    conv = Yorishiro::Conversation.new
    @cli.instance_variable_set(:@conversation, conv)

    @cli.send(:execute_read_only_tool_calls, [{ id: "tc_1", name: "recording_tool", arguments: {} }])

    refute tool.executed, "non-read-only tool must not run in plan mode"
    result = conv.messages.last
    assert_equal :tool, result[:role]
    assert_equal "tc_1", result[:tool_call_id]
    assert_includes result[:content], "not available in plan mode"
    assert_includes @output.string, "[Plan Mode] Blocked non-read-only tool: recording_tool"
  ensure
    Yorishiro.reset!
  end

  def test_plan_mode_executes_read_only_tool_without_permission_prompt
    Yorishiro.reset!
    tool = ReadOnlyRecordingTool.new # permission_check is :ask, but plan mode runs it inline
    Yorishiro.configuration.allow_tool(tool)
    conv = Yorishiro::Conversation.new
    @cli.instance_variable_set(:@conversation, conv)

    @cli.send(:execute_read_only_tool_calls, [{ id: "tc_1", name: "read_only_recording_tool", arguments: {} }])

    assert tool.executed
    result = conv.messages.last
    assert_equal :tool, result[:role]
    assert_equal "recorded ok", result[:content]
    refute_includes @output.string, "[Permission]"
  ensure
    Yorishiro.reset!
  end

  def test_plan_mode_blocked_tool_still_reports_result_for_every_call
    Yorishiro.reset!
    write_tool = RecordingTool.new
    read_tool = ReadOnlyRecordingTool.new
    Yorishiro.configuration.allow_tool(write_tool)
    Yorishiro.configuration.allow_tool(read_tool)
    conv = Yorishiro::Conversation.new
    @cli.instance_variable_set(:@conversation, conv)

    @cli.send(:execute_read_only_tool_calls, [
                { id: "tc_1", name: "recording_tool", arguments: {} },
                { id: "tc_2", name: "read_only_recording_tool", arguments: {} }
              ])

    # Both calls got a tool result, so no assistant tool_call is left dangling.
    result_ids = conv.messages.select { |m| m[:role] == :tool }.map { |m| m[:tool_call_id] }
    assert_equal %w[tc_1 tc_2], result_ids
    refute write_tool.executed
    assert read_tool.executed
  ensure
    Yorishiro.reset!
  end

  def test_plan_mode_records_results_for_siblings_of_exit_plan_mode
    Yorishiro.reset!
    read_tool = ReadOnlyRecordingTool.new
    Yorishiro.configuration.allow_tool(read_tool)
    conv = Yorishiro::Conversation.new
    @cli.instance_variable_set(:@conversation, conv)
    @cli.instance_variable_set(:@provider, ScriptedProvider.new(
                                             { content: "", tool_calls: [
                                               { id: "tc_read", name: "read_only_recording_tool", arguments: {} },
                                               { id: "tc_exit", name: "exit_plan_mode",
                                                 arguments: { "plan" => "1. Do the thing" } }
                                             ] }
                                           ))

    simulate_input("n") do
      @cli.send(:plan_then_execute)
    end

    # Every tool call got a result, so no assistant tool_call dangles when
    # the follow-up completion sends the history back to the provider.
    tool_results = conv.messages.select { |m| m[:role] == :tool }
    assert_equal %w[tc_exit tc_read], tool_results.map { |m| m[:tool_call_id] }.sort
    refute read_tool.executed, "siblings of exit_plan_mode must not run"
    skipped = tool_results.find { |m| m[:tool_call_id] == "tc_read" }
    assert_includes skipped[:content], "Skipped"
    assert_includes @output.string, "1. Do the thing"
    assert_includes @output.string, "Plan execution cancelled."
  ensure
    Yorishiro.reset!
  end

  def test_agent_loop_does_not_record_empty_assistant_response
    Yorishiro.reset!
    conv = Yorishiro::Conversation.new
    conv.add_message(:user, "hello")
    @cli.instance_variable_set(:@conversation, conv)
    @cli.instance_variable_set(:@provider, ScriptedProvider.new({ content: "", tool_calls: [] }))

    @cli.send(:agent_loop)

    # The empty completion is warned about but never enters the history —
    # Anthropic would reject it on every later request.
    assert_equal([:user], conv.messages.map { |m| m[:role] })
    assert_includes @output.string, "empty response"
  ensure
    Yorishiro.reset!
  end

  def test_agent_loop_records_normal_assistant_response
    Yorishiro.reset!
    conv = Yorishiro::Conversation.new
    conv.add_message(:user, "hello")
    @cli.instance_variable_set(:@conversation, conv)
    @cli.instance_variable_set(:@provider, ScriptedProvider.new({ content: "hi there", tool_calls: [] }))

    @cli.send(:agent_loop)

    assert_equal(%i[user assistant], conv.messages.map { |m| m[:role] })
    assert_equal "hi there", conv.messages.last[:content]
  ensure
    Yorishiro.reset!
  end

  private

  def setup_session_cli(store)
    @cli.instance_variable_set(:@conversation, Yorishiro::Conversation.new)
    @cli.instance_variable_set(:@provider, FakeProvider.new(budget: nil))
    @cli.instance_variable_set(:@plan_mode, false)
    @cli.instance_variable_set(:@session_store, store)
    @cli.instance_variable_set(:@session_id, nil)
  end

  def simulate_input(text)
    old_stdin = $stdin
    $stdin = StringIO.new(text)
    # Reline.readline receives (prompt, add_hist) — return the simulated text
    fake_readline = ->(_prompt, _add_hist = false) { text }
    Reline.stub(:readline, fake_readline) do
      yield
    end
  ensure
    $stdin = old_stdin
  end
end
