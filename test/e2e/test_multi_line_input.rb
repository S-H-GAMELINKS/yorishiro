# frozen_string_literal: true

require_relative "test_helper"

class TestMultiLineInput < Minitest::Test
  def setup
    Yorishiro.reset!
  end

  def test_newlines_preserved_in_message
    runner = Yorishiro::E2E::ScriptRunner.new

    runner.input("line 1\nline 2\nline 3")

    messages = runner.conversation.messages
    assert_equal "line 1\nline 2\nline 3", messages[0][:content]
  end

  def test_empty_lines_in_message
    runner = Yorishiro::E2E::ScriptRunner.new

    runner.input("before\n\nafter")

    messages = runner.conversation.messages
    assert_equal "before\n\nafter", messages[0][:content]
  end

  def test_multiple_turns_mixed_input
    runner = Yorishiro::E2E::ScriptRunner.new

    runner
      .input("single line")
      .input("multi\nline\ninput")
      .assert_conversation_length(4)
  end
end
