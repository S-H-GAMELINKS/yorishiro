# frozen_string_literal: true

require_relative "test_helper"

class TestChatFlow < Minitest::Test
  def setup
    Yorishiro.reset!
  end

  def test_single_turn_conversation
    runner = Yorishiro::E2E::ScriptRunner.new

    runner
      .input("Hello")
      .assert_output_contains("Mock response from Yorishiro")
      .assert_conversation_length(2)
      .assert_last_role(:assistant)
  end

  def test_multi_turn_conversation
    runner = Yorishiro::E2E::ScriptRunner.new

    runner
      .input("Hello")
      .assert_conversation_length(2)
      .input("How are you?")
      .assert_conversation_length(4)
      .assert_last_role(:assistant)
  end

  def test_custom_responses
    provider = Yorishiro::E2E::MockProvider.new
    provider.responses = ["First response", "Second response"]

    runner = Yorishiro::E2E::ScriptRunner.new(provider: provider)
    runner
      .input("First")
      .assert_output_contains("First response")
      .input("Second")
      .assert_output_contains("Second response")
  end

  def test_message_preservation
    runner = Yorishiro::E2E::ScriptRunner.new

    runner.input("Hello")

    messages = runner.conversation.messages
    assert_equal :user, messages[0][:role]
    assert_equal "Hello", messages[0][:content]
    assert_equal :assistant, messages[1][:role]
  end
end
