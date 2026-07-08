# frozen_string_literal: true

require "test_helper"

class TestSubAgent < Minitest::Test
  # Scripted provider: returns responses in order, repeating the last one
  # when the script runs out (so iteration-limit tests can loop forever).
  class ScriptedProvider
    attr_reader :chat_calls, :seen_tools, :conversation

    def initialize(responses, budget: nil)
      @responses = responses
      @budget = budget
      @chat_calls = 0
      @seen_tools = []
    end

    def context_budget_tokens = @budget

    def chat(conversation, tools: [], &)
      @chat_calls += 1
      @seen_tools << tools
      @conversation = conversation
      @responses.length > 1 ? @responses.shift : @responses.first
    end
  end

  class EchoTool < Yorishiro::Tool
    attr_reader :calls

    def initialize(result: "echo result")
      super()
      @result = result
      @calls = []
    end

    def name = "echo"
    def description = "echoes a fixed result"
    def parameters = { type: "object" }
    def read_only? = true

    def execute(**params)
      @calls << params
      @result
    end
  end

  class RaisingTool < EchoTool
    def execute(**_params) = raise "tool boom"
  end

  ECHO_CALL = {
    content: "",
    tool_calls: [{ id: "tc_1", name: "echo", arguments: { "query" => "find it" } }]
  }.freeze

  def setup
    @output = StringIO.new
    @hooks = Yorishiro::Hooks.new
  end

  def build_sub_agent(provider, tools, **)
    Yorishiro::SubAgent.new(provider: provider, tools: tools, output: @output, hooks: @hooks, **)
  end

  def test_runs_tools_and_returns_final_text
    provider = ScriptedProvider.new([ECHO_CALL.dup, { content: "FINDINGS", tool_calls: [] }])
    tool = EchoTool.new

    result = build_sub_agent(provider, [tool]).run("investigate")

    assert_equal "FINDINGS", result
    assert_equal [{ query: "find it" }], tool.calls
    assert_equal 2, provider.chat_calls
    assert_includes @output.string, "  [task] echo(query: find it)"

    tool_message = provider.conversation.messages.find { |m| m[:role] == :tool }
    assert_equal "echo result", tool_message[:content]
  end

  def test_passes_tool_definitions_to_provider
    provider = ScriptedProvider.new([{ content: "done", tool_calls: [] }])

    build_sub_agent(provider, [EchoTool.new]).run("investigate")

    assert_equal(["echo"], provider.seen_tools.first.map { |d| d[:name] })
  end

  def test_iteration_limit_skips_pending_tool_calls
    provider = ScriptedProvider.new([ECHO_CALL.dup])
    tool = EchoTool.new

    result = build_sub_agent(provider, [tool], max_iterations: 2).run("investigate")

    assert_equal 2, provider.chat_calls
    assert_equal 1, tool.calls.length # pending calls at the limit are not executed
    assert_includes result, "reached the 2-iteration limit"
  end

  def test_iteration_limit_keeps_last_assistant_text
    provider = ScriptedProvider.new([ECHO_CALL.merge(content: "partial findings")])

    result = build_sub_agent(provider, [EchoTool.new], max_iterations: 2).run("investigate")

    assert_includes result, "partial findings"
    assert_includes result, "iteration limit"
  end

  def test_before_hook_denies_tool
    @hooks.on(:before_tool_use) { |name, _args| Yorishiro::Hooks::Denial.new("policy") if name == "echo" }
    provider = ScriptedProvider.new([ECHO_CALL.dup, { content: "done", tool_calls: [] }])
    tool = EchoTool.new

    result = build_sub_agent(provider, [tool]).run("investigate")

    assert_equal "done", result
    assert_empty tool.calls
    tool_message = provider.conversation.messages.find { |m| m[:role] == :tool }
    assert_includes tool_message[:content], "denied by hook: policy"
  end

  def test_after_hook_receives_result
    received = nil
    @hooks.on(:after_tool_use) { |name, args, result| received = [name, args, result] }
    provider = ScriptedProvider.new([ECHO_CALL.dup, { content: "done", tool_calls: [] }])

    build_sub_agent(provider, [EchoTool.new]).run("investigate")

    assert_equal ["echo", { "query" => "find it" }, "echo result"], received
  end

  def test_after_hook_error_warns_but_keeps_result
    @hooks.on(:after_tool_use) { raise "observer broke" }
    provider = ScriptedProvider.new([ECHO_CALL.dup, { content: "done", tool_calls: [] }])

    result = build_sub_agent(provider, [EchoTool.new]).run("investigate")

    assert_equal "done", result
    tool_message = provider.conversation.messages.find { |m| m[:role] == :tool }
    assert_equal "echo result", tool_message[:content]
    assert_includes @output.string, "after_tool_use hook error: observer broke"
  end

  def test_unknown_tool_records_error_and_continues
    call = { content: "", tool_calls: [{ id: "tc_1", name: "bogus", arguments: {} }] }
    provider = ScriptedProvider.new([call, { content: "done", tool_calls: [] }])

    result = build_sub_agent(provider, [EchoTool.new]).run("investigate")

    assert_equal "done", result
    tool_message = provider.conversation.messages.find { |m| m[:role] == :tool }
    assert_includes tool_message[:content], "Unknown tool 'bogus'"
  end

  def test_raising_tool_records_error_and_continues
    provider = ScriptedProvider.new([ECHO_CALL.dup, { content: "done", tool_calls: [] }])

    result = build_sub_agent(provider, [RaisingTool.new]).run("investigate")

    assert_equal "done", result
    tool_message = provider.conversation.messages.find { |m| m[:role] == :tool }
    assert_equal "Error: tool boom", tool_message[:content]
  end

  def test_caps_oversized_tool_results
    provider = ScriptedProvider.new([ECHO_CALL.dup, { content: "done", tool_calls: [] }], budget: 100)
    tool = EchoTool.new(result: "z" * 5_000)

    build_sub_agent(provider, [tool]).run("investigate")

    tool_message = provider.conversation.messages.find { |m| m[:role] == :tool }
    assert_operator tool_message[:content].length, :<, 2_500 # floor: MIN_TOOL_RESULT_CHARS
    assert_includes tool_message[:content], "tool output truncated"
  end

  def test_blank_final_content_returns_fallback
    provider = ScriptedProvider.new([{ content: "", tool_calls: [] }])

    result = build_sub_agent(provider, [EchoTool.new]).run("investigate")

    assert_equal "The subagent returned no findings.", result
  end

  def test_manages_context_by_eliding_old_tool_results
    calls = (1..4).map do |i|
      { content: "", tool_calls: [{ id: "tc_#{i}", name: "echo", arguments: {} }] }
    end
    provider = ScriptedProvider.new(calls + [{ content: "done", tool_calls: [] }], budget: 400)
    tool = EchoTool.new(result: "w" * 800)

    build_sub_agent(provider, [tool]).run("investigate")

    elided = provider.conversation.messages.count { |m| m[:content] == Yorishiro::Conversation::ELIDED_TOOL_RESULT }
    assert_operator elided, :>=, 1 # old results were blanked to stay near the budget
    refute_includes @output.string, "[i]" # the subagent shrinks silently
  end
end
