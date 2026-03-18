# frozen_string_literal: true

require "test_helper"

class TestTool < Minitest::Test
  def test_name_not_implemented
    assert_raises(Yorishiro::ToolNotImplementedError) { Yorishiro::Tool.new.name }
  end

  def test_description_not_implemented
    assert_raises(Yorishiro::ToolNotImplementedError) { Yorishiro::Tool.new.description }
  end

  def test_parameters_not_implemented
    assert_raises(Yorishiro::ToolNotImplementedError) { Yorishiro::Tool.new.parameters }
  end

  def test_execute_not_implemented
    assert_raises(Yorishiro::ToolNotImplementedError) { Yorishiro::Tool.new.execute }
  end

  def test_default_read_only
    refute Yorishiro::Tool.new.read_only?
  end

  def test_default_permission_check
    assert_equal :allowed, Yorishiro::Tool.new.permission_check({})
  end
end
