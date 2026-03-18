# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TestToolExecution < Minitest::Test
  def setup
    Yorishiro.reset!
  end

  def test_read_file_tool_execution
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.txt")
      File.write(path, "hello world")

      provider = Yorishiro::E2E::MockProvider.new
      provider.tool_call_responses = [
        {
          content: "",
          tool_calls: [{
            id: "tc_1",
            name: "read_file",
            arguments: { "path" => path }
          }]
        }
      ]
      provider.responses = ["I read the file."]

      runner = Yorishiro::E2E::ScriptRunner.new(provider: provider)
                                           .with_tools(Yorishiro::Tools::ReadFile.new)

      runner
        .input("Read the file")
        .assert_tool_called("read_file")
    end
  end

  def test_list_files_tool_execution
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "")
      File.write(File.join(dir, "b.rb"), "")

      provider = Yorishiro::E2E::MockProvider.new
      provider.tool_call_responses = [
        {
          content: "",
          tool_calls: [{
            id: "tc_1",
            name: "list_files",
            arguments: { "path" => dir }
          }]
        }
      ]
      provider.responses = ["Here are the files."]

      runner = Yorishiro::E2E::ScriptRunner.new(provider: provider)
                                           .with_tools(Yorishiro::Tools::ListFiles.new)

      runner
        .input("List files")
        .assert_tool_called("list_files")
    end
  end

  def test_tool_result_added_to_conversation
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.txt")
      File.write(path, "file content")

      provider = Yorishiro::E2E::MockProvider.new
      provider.tool_call_responses = [
        {
          content: "",
          tool_calls: [{
            id: "tc_1",
            name: "read_file",
            arguments: { "path" => path }
          }]
        }
      ]
      provider.responses = ["Done."]

      runner = Yorishiro::E2E::ScriptRunner.new(provider: provider)
                                           .with_tools(Yorishiro::Tools::ReadFile.new)

      runner.input("Read it")

      tool_messages = runner.conversation.messages.select { |m| m[:role] == :tool }
      assert_equal 1, tool_messages.length
      assert_equal "tc_1", tool_messages[0][:tool_call_id]
      assert_includes tool_messages[0][:content], "file content"
    end
  end
end
