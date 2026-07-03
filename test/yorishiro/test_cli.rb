# frozen_string_literal: true

require "test_helper"

class TestCLI < Minitest::Test
  class FakeTool < Yorishiro::Tool
    def name = "write_file"
    def description = "Write a file"
    def parameters = { type: "object" }
  end

  class FakeProvider
    attr_accessor :budget
    attr_reader :chat_calls

    def initialize(budget: nil)
      @budget = budget
      @chat_calls = 0
    end

    def context_budget_tokens = @budget

    def chat(_conversation, tools: [], &) # rubocop:disable Lint/UnusedMethodArgument
      @chat_calls += 1
      { content: "SUMMARY", tool_calls: [], meta: {} }
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

  private

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
