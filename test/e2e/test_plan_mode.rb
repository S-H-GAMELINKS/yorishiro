# frozen_string_literal: true

require_relative "test_helper"

class TestPlanMode < Minitest::Test
  def setup
    Yorishiro.reset!
  end

  def test_plan_mode_provider_called_without_tools
    call_count = 0

    provider = Yorishiro::E2E::MockProvider.new
    provider.define_singleton_method(:chat) do |_conversation, tools: [], &block| # rubocop:disable Lint/UnusedBlockArgument
      call_count += 1
      text = "Here is my plan: step 1, step 2, step 3."
      block&.call(text)
      { content: text, tool_calls: [] }
    end

    runner = Yorishiro::E2E::ScriptRunner.new(provider: provider)
    runner.input("Create a test file")

    assert_equal 1, call_count
    assert_output_present = runner.conversation.messages.any? { |m| m[:role] == :assistant }
    assert assert_output_present
  end

  def test_conversation_state_after_plan
    provider = Yorishiro::E2E::MockProvider.new
    provider.responses = ["Plan: 1. Read file 2. Modify 3. Write"]

    runner = Yorishiro::E2E::ScriptRunner.new(provider: provider)
    runner.input("Create a test file")

    assert_equal 2, runner.conversation.length
    assert_equal :user, runner.conversation.messages[0][:role]
    assert_equal :assistant, runner.conversation.messages[1][:role]
    assert_includes runner.conversation.messages[1][:content], "Plan:"
  end

  def test_plan_mode_passes_read_only_tools
    received_tools = nil

    provider = Yorishiro::E2E::MockProvider.new
    provider.define_singleton_method(:chat) do |_conversation, tools: [], &block|
      received_tools = tools
      text = "Here is my plan."
      block&.call(text)
      { content: text, tool_calls: [] }
    end

    Yorishiro.configuration.allow_tool(Yorishiro::Tools::ReadFile.new)
    Yorishiro.configuration.allow_tool(Yorishiro::Tools::ListFiles.new)
    Yorishiro.configuration.allow_tool(Yorishiro::Tools::WriteFile.new)
    Yorishiro.configuration.allow_tool(Yorishiro::Tools::ExecuteCommand.new)

    runner = Yorishiro::E2E::PlanRunner.new(provider: provider)
    runner.input("Describe the project structure")

    tool_names = received_tools.map { |t| t[:name] }
    assert_includes tool_names, "read_file"
    assert_includes tool_names, "list_files"
    assert_includes tool_names, "exit_plan_mode"
    refute_includes tool_names, "write_file"
    refute_includes tool_names, "execute_command"
  end

  def test_plan_mode_exits_loop_when_exit_plan_mode_called
    call_index = 0

    provider = Yorishiro::E2E::MockProvider.new
    provider.define_singleton_method(:chat) do |_conversation, tools: [], &block| # rubocop:disable Lint/UnusedBlockArgument
      call_index += 1
      if call_index == 1
        # First call: LLM keeps reading.
        text = "Let me read the file first."
        block&.call(text)
        {
          content: text,
          tool_calls: [
            { id: "tc_1", name: "read_file", arguments: { "path" => __FILE__ } }
          ]
        }
      else
        # Second call: LLM signals the plan is ready via exit_plan_mode.
        {
          content: "",
          tool_calls: [
            { id: "tc_2", name: "exit_plan_mode", arguments: { "plan" => "1. Read 2. Modify 3. Write" } }
          ]
        }
      end
    end

    Yorishiro.configuration.allow_tool(Yorishiro::Tools::ReadFile.new)

    runner = Yorishiro::E2E::PlanRunner.new(provider: provider)
    runner.input("Read the file and make a plan")

    # Loop stops right after exit_plan_mode (no third completion requested).
    assert_equal 2, call_index
    # user + assistant(read_file) + tool_result + assistant(exit_plan_mode) + tool_result
    assert_equal 5, runner.conversation.length
    assert_equal :tool, runner.conversation.messages.last[:role]
  end

  def test_plan_mode_executes_read_only_tool_calls
    call_index = 0

    provider = Yorishiro::E2E::MockProvider.new
    provider.define_singleton_method(:chat) do |_conversation, tools: [], &block| # rubocop:disable Lint/UnusedBlockArgument
      call_index += 1
      if call_index == 1
        # First call: LLM requests a read_file tool call
        text = "Let me read the file first."
        block&.call(text)
        {
          content: text,
          tool_calls: [
            { id: "tc_1", name: "read_file", arguments: { "path" => __FILE__ } }
          ]
        }
      else
        # Second call: LLM returns the plan
        text = "Here is my plan based on the file."
        block&.call(text)
        { content: text, tool_calls: [] }
      end
    end

    Yorishiro.configuration.allow_tool(Yorishiro::Tools::ReadFile.new)
    Yorishiro.configuration.allow_tool(Yorishiro::Tools::WriteFile.new)

    runner = Yorishiro::E2E::PlanRunner.new(provider: provider)
    runner.input("Read the plan mode test file and make a plan")

    assert_equal 2, call_index
    # user + assistant(tool_call) + tool_result + assistant(plan)
    assert_equal 4, runner.conversation.length
  end
end
