# frozen_string_literal: true

require "test_helper"

class TestToolResultCap < Minitest::Test
  def test_passes_small_output_through
    assert_equal "small output", Yorishiro::ToolResultCap.cap("small output", budget: nil)
  end

  def test_caps_output_without_budget
    output = "x" * 40_000

    capped = Yorishiro::ToolResultCap.cap(output, budget: nil)

    assert_operator capped.length, :<, 31_000
    assert_includes capped, "tool output truncated"
    assert_includes capped, "showing 30000 of 40000 characters"
  end

  def test_caps_output_scaled_to_budget
    output = "y" * 20_000

    capped = Yorishiro::ToolResultCap.cap(output, budget: 8_000) # limit: 8000 chars

    assert_operator capped.length, :<, 8_500
    assert_includes capped, "tool output truncated"
  end

  def test_max_chars_scales_with_budget
    assert_equal 8_000, Yorishiro::ToolResultCap.max_chars(8_000) # 8000 tokens * 4 chars/token / 4
  end

  def test_max_chars_floors_at_minimum
    assert_equal 2_000, Yorishiro::ToolResultCap.max_chars(100)
  end

  def test_max_chars_default_without_budget
    assert_equal 30_000, Yorishiro::ToolResultCap.max_chars(nil)
  end
end
