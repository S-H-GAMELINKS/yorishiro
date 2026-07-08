# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TestSubagentE2E < Minitest::Test
  def setup
    Yorishiro.reset!
  end

  # The core context-isolation property: the subagent reads a file, but only
  # its summary reaches the parent conversation — the raw file content never
  # enters any parent message.
  def test_task_tool_keeps_raw_tool_output_out_of_parent_conversation
    Dir.mktmpdir do |dir|
      path = File.join(dir, "secret_config.rb")
      File.write(path, "RAW_FILE_CONTENT = 'very long implementation detail'")

      task_tool = Yorishiro::Tools::Task.new
      subagent_output = StringIO.new
      task_tool.attach(provider: child_provider(path), output: subagent_output)

      runner = Yorishiro::E2E::ScriptRunner.new(provider: parent_provider(path))
                                           .with_tools(Yorishiro::Tools::ReadFile.new, task_tool)

      runner
        .input("What does the config file define?")
        .assert_tool_called("task")

      tool_messages = runner.conversation.messages.select { |m| m[:role] == :tool }
      assert_equal 1, tool_messages.length
      assert_includes tool_messages[0][:content], "SUMMARY"

      runner.conversation.messages.each do |message|
        refute_includes message[:content].to_s, "very long implementation detail"
      end

      assert_includes subagent_output.string, "  [task] read_file("
    end
  end

  private

  def parent_provider(path)
    provider = Yorishiro::E2E::MockProvider.new
    provider.tool_call_responses = [
      {
        content: "",
        tool_calls: [{
          id: "tc_1",
          name: "task",
          arguments: { "prompt" => "Read #{path} and summarize what it defines." }
        }]
      }
    ]
    provider.responses = ["The file defines a constant."]
    provider
  end

  def child_provider(path)
    provider = Yorishiro::E2E::MockProvider.new
    provider.tool_call_responses = [
      {
        content: "",
        tool_calls: [{
          id: "sub_1",
          name: "read_file",
          arguments: { "path" => path }
        }]
      }
    ]
    provider.responses = ["SUMMARY: defines RAW_FILE_CONTENT constant name only."]
    provider
  end
end
