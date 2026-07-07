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

  def test_serializable_messages_returns_detached_copy
    @conversation.add_message(:user, "hello")

    copy = @conversation.serializable_messages
    copy.first["content"] = "mutated"

    assert_equal "hello", @conversation.messages.first[:content]
  end

  def test_restore_messages_round_trips_through_json
    tool_calls = [{ id: "tc_1", name: "read_file", arguments: { "path" => "/tmp/test" } }]
    @conversation.add_message(:user, "read it")
    @conversation.add_message(:assistant, "", tool_calls: tool_calls)
    @conversation.add_tool_result(tool_call_id: "tc_1", content: "file contents")
    original_api_messages = @conversation.to_api_messages

    raw = JSON.parse(JSON.generate(@conversation.serializable_messages))
    restored = Yorishiro::Conversation.new
    restored.restore_messages!(raw)

    # Provider-facing conversion must match, so a resumed conversation is
    # indistinguishable from a live one.
    assert_equal JSON.generate(original_api_messages), JSON.generate(restored.to_api_messages)
    assert_equal :assistant, restored.messages[1][:role]
    assert_equal "read_file", restored.messages[1][:tool_calls].first[:name]
  end

  def test_restore_messages_rejects_invalid_role
    assert_raises(ArgumentError) { @conversation.restore_messages!([{ "role" => "wizard", "content" => "x" }]) }
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

  def test_estimated_tokens_includes_system_prompt
    conv = Yorishiro::Conversation.new(system_prompt: "a" * 40)
    conv.add_message(:user, "b" * 40)
    # (40 + 40) / 4 = 20
    assert_equal 20, conv.estimated_tokens
  end

  def test_trim_to_budget_keeps_within_budget
    10.times do
      @conversation.add_message(:user, "u" * 400)
      @conversation.add_message(:assistant, "a" * 400)
    end

    removed = @conversation.trim_to_budget!(max_tokens: 300)
    assert_operator removed, :>, 0
    assert_operator @conversation.estimated_tokens, :<=, 300
  end

  def test_trim_to_budget_keeps_latest_round
    @conversation.add_message(:user, "old question " * 100)
    @conversation.add_message(:assistant, "old answer " * 100)
    @conversation.add_message(:user, "latest question")
    @conversation.add_message(:assistant, "latest answer")

    @conversation.trim_to_budget!(max_tokens: 20)

    # The most recent round is always preserved.
    assert_equal "latest question", @conversation.messages[0][:content]
    assert_equal :user, @conversation.messages[0][:role]
  end

  def test_trim_to_budget_preserves_tool_call_pairs
    # Round 1: large, should be dropped whole (assistant tool_call + tool result together)
    @conversation.add_message(:user, "read a big file " * 100)
    @conversation.add_message(:assistant, "", tool_calls: [{ id: "tc_1", name: "read_file", arguments: {} }])
    @conversation.add_tool_result(tool_call_id: "tc_1", content: "x" * 4000)
    # Round 2: latest, kept
    @conversation.add_message(:user, "thanks")

    @conversation.trim_to_budget!(max_tokens: 50)

    # No orphaned tool result should remain (tool without its assistant tool_call).
    refute(@conversation.messages.any? { |m| m[:role] == :tool })
    assert_equal "thanks", @conversation.messages.last[:content]
  end

  def test_trim_to_budget_never_drops_only_round
    @conversation.add_message(:user, "u" * 4000)
    @conversation.add_message(:assistant, "a" * 4000)

    removed = @conversation.trim_to_budget!(max_tokens: 10)
    # Only one round exists; it must be kept even though it exceeds the budget.
    assert_equal 0, removed
    assert_equal 2, @conversation.length
  end

  def test_compact_summarizes_old_rounds
    4.times do |i|
      @conversation.add_message(:user, "q#{i}")
      @conversation.add_message(:assistant, "a#{i}")
    end

    removed = @conversation.compact!(keep_recent_rounds: 2) { |old| "SUMMARY(#{old.length})" }

    assert_equal 4, removed # oldest 2 rounds = 4 messages
    assert_equal :user, @conversation.messages[0][:role]
    assert_includes @conversation.messages[0][:content], "SUMMARY(4)"
    # 1 summary + 2 recent rounds (4 messages)
    assert_equal 5, @conversation.length
    assert_equal "a3", @conversation.messages.last[:content]
  end

  def test_compact_noop_when_not_enough_rounds
    @conversation.add_message(:user, "q")
    @conversation.add_message(:assistant, "a")

    called = false
    removed = @conversation.compact!(keep_recent_rounds: 2) do |_old|
      called = true
      "S"
    end

    assert_equal 0, removed
    refute called
    assert_equal 2, @conversation.length
  end

  def test_compact_noop_on_empty_summary
    4.times do |i|
      @conversation.add_message(:user, "q#{i}")
      @conversation.add_message(:assistant, "a#{i}")
    end

    removed = @conversation.compact!(keep_recent_rounds: 2) { |_old| "  " }

    assert_equal 0, removed
    assert_equal 8, @conversation.length # unchanged
  end

  def test_compact_preserves_tool_pairs
    @conversation.add_message(:user, "read a file")
    @conversation.add_message(:assistant, "", tool_calls: [{ id: "t1", name: "read_file", arguments: {} }])
    @conversation.add_tool_result(tool_call_id: "t1", content: "data")
    @conversation.add_message(:user, "q1")
    @conversation.add_message(:assistant, "a1")
    @conversation.add_message(:user, "q2")
    @conversation.add_message(:assistant, "a2")

    removed = @conversation.compact!(keep_recent_rounds: 2) { |_old| "S" }

    assert_equal 3, removed # first round: user + assistant(tool_call) + tool result
    refute(@conversation.messages.any? { |m| m[:role] == :tool })
  end
end
