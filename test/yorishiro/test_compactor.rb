# frozen_string_literal: true

require "test_helper"

class TestCompactor < Minitest::Test
  class StubProvider
    attr_reader :last_conversation, :chat_calls

    def initialize
      @chat_calls = 0
    end

    def chat(conversation, tools: [], &) # rubocop:disable Lint/UnusedMethodArgument
      @chat_calls += 1
      @last_conversation = conversation
      { content: "SUMMARY TEXT", tool_calls: [], meta: {} }
    end
  end

  def test_compact_replaces_old_history_with_summary
    provider = StubProvider.new
    conv = Yorishiro::Conversation.new
    4.times do |i|
      conv.add_message(:user, "question #{i}")
      conv.add_message(:assistant, "answer #{i}")
    end

    compacted = Yorishiro::Compactor.new(provider).compact(conv)

    assert_equal 4, compacted
    assert_equal 1, provider.chat_calls
    assert_includes conv.messages[0][:content], "SUMMARY TEXT"
    # The most recent round is preserved verbatim.
    assert_equal "answer 3", conv.messages.last[:content]
  end

  def test_compact_sends_old_transcript_to_provider
    provider = StubProvider.new
    conv = Yorishiro::Conversation.new
    4.times do |i|
      conv.add_message(:user, "question #{i}")
      conv.add_message(:assistant, "answer #{i}")
    end

    Yorishiro::Compactor.new(provider).compact(conv)

    request_text = provider.last_conversation.messages[0][:content]
    assert_includes request_text, "question 0"
    assert_includes request_text, "answer 1"
  end

  def test_compact_noop_when_conversation_short
    provider = StubProvider.new
    conv = Yorishiro::Conversation.new
    conv.add_message(:user, "hi")
    conv.add_message(:assistant, "yo")

    assert_equal 0, Yorishiro::Compactor.new(provider).compact(conv)
    assert_equal 0, provider.chat_calls
  end
end
