# frozen_string_literal: true

require "test_helper"

class TestConversation < Minitest::Test
  def setup
    @conversation = Yorishiro::Conversation.new
  end

  def test_empty_initial_state
    assert_empty @conversation.messages
    assert_equal 0, @conversation.length
  end

  def test_add_user_message
    @conversation.add_message(:user, "Hello")
    assert_equal 1, @conversation.length
    assert_equal :user, @conversation.messages.last[:role]
    assert_equal "Hello", @conversation.messages.last[:content]
  end

  def test_add_assistant_message
    @conversation.add_message(:assistant, "Hi there!")
    assert_equal :assistant, @conversation.messages.last[:role]
  end

  def test_add_message_with_tool_calls
    tool_calls = [{ id: "tc_1", name: "read_file", arguments: { path: "/tmp/test" } }]
    @conversation.add_message(:assistant, "Let me read that.", tool_calls: tool_calls)
    assert_equal tool_calls, @conversation.messages.last[:tool_calls]
  end

  def test_add_tool_result
    @conversation.add_tool_result(tool_call_id: "tc_1", content: "file contents")
    assert_equal :tool, @conversation.messages.last[:role]
    assert_equal "tc_1", @conversation.messages.last[:tool_call_id]
  end

  def test_invalid_role_raises
    assert_raises(ArgumentError) { @conversation.add_message(:invalid, "test") }
  end

  def test_clear
    @conversation.add_message(:user, "Hello")
    @conversation.add_message(:assistant, "Hi")
    @conversation.clear
    assert_empty @conversation.messages
  end

  def test_last_role
    assert_nil @conversation.last_role
    @conversation.add_message(:user, "Hello")
    assert_equal :user, @conversation.last_role
    @conversation.add_message(:assistant, "Hi")
    assert_equal :assistant, @conversation.last_role
  end

  def test_to_api_messages_without_system_prompt
    @conversation.add_message(:user, "Hello")
    msgs = @conversation.to_api_messages
    assert_equal 1, msgs.length
    assert_equal "user", msgs[0][:role]
  end

  def test_to_api_messages_with_system_prompt
    conv = Yorishiro::Conversation.new(system_prompt: "You are helpful.")
    conv.add_message(:user, "Hello")
    msgs = conv.to_api_messages
    assert_equal 2, msgs.length
    assert_equal "system", msgs[0][:role]
    assert_equal "You are helpful.", msgs[0][:content]
  end

  def test_large_conversation
    100.times do |i|
      @conversation.add_message(:user, "Message #{i}")
      @conversation.add_message(:assistant, "Response #{i}")
    end
    assert_equal 200, @conversation.length
  end
end
