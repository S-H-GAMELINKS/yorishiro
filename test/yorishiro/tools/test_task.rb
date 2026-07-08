# frozen_string_literal: true

require "test_helper"

class TestTaskTool < Minitest::Test
  class FakeProvider
    attr_reader :seen_tools

    def initialize(responses)
      @responses = responses
      @seen_tools = []
    end

    def context_budget_tokens = nil

    def chat(_conversation, tools: [], &)
      @seen_tools << tools
      @responses.length > 1 ? @responses.shift : @responses.first
    end
  end

  class ReadOnlyTool < Yorishiro::Tool
    def name = "fake_read"
    def description = "reads"
    def parameters = { type: "object" }
    def read_only? = true
    def execute(**_params) = "read ok"
  end

  class WritingTool < ReadOnlyTool
    def name = "fake_write"
    def read_only? = false
  end

  def setup
    Yorishiro.reset!
    @tool = Yorishiro::Tools::Task.new
    @output = StringIO.new
  end

  def teardown
    Yorishiro.reset!
  end

  def test_definition
    definition = @tool.definition

    assert_equal "task", definition[:name]
    assert_equal ["prompt"], definition[:input_schema][:required]
    assert @tool.read_only?
    assert_equal :allowed, @tool.permission_check({})
  end

  def test_execute_returns_subagent_findings
    provider = FakeProvider.new([{ content: "FINDINGS", tool_calls: [] }])
    @tool.attach(provider: provider, output: @output)

    assert_equal "FINDINGS", @tool.execute(prompt: "investigate the codebase")
  end

  def test_execute_accepts_string_keys
    provider = FakeProvider.new([{ content: "ok", tool_calls: [] }])
    @tool.attach(provider: provider, output: @output)

    assert_equal "ok", @tool.execute("prompt" => "investigate", "description" => "quick check")
  end

  def test_subagent_gets_read_only_tools_without_task
    Yorishiro.configuration.allow_tool(ReadOnlyTool.new)
    Yorishiro.configuration.allow_tool(WritingTool.new)
    Yorishiro.configuration.allow_tool(@tool)
    provider = FakeProvider.new([{ content: "done", tool_calls: [] }])
    @tool.attach(provider: provider, output: @output)

    @tool.execute(prompt: "investigate")

    child_tool_names = provider.seen_tools.first.map { |d| d[:name] }
    assert_includes child_tool_names, "fake_read"
    refute_includes child_tool_names, "fake_write" # writing tools stay out of the subagent
    refute_includes child_tool_names, "task" # subagents cannot nest
  end

  def test_execute_requires_prompt
    @tool.attach(provider: FakeProvider.new([]), output: @output)

    error = assert_raises(RuntimeError) { @tool.execute(description: "no prompt") }
    assert_includes error.message, "prompt is required"

    assert_raises(RuntimeError) { @tool.execute(prompt: "   ") }
  end
end
