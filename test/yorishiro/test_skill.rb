# frozen_string_literal: true

require "test_helper"

class TestSkill < Minitest::Test
  def test_name_not_implemented
    assert_raises(Yorishiro::SkillNotImplementedError) { Yorishiro::Skill.new.name }
  end

  def test_description_not_implemented
    assert_raises(Yorishiro::SkillNotImplementedError) { Yorishiro::Skill.new.description }
  end

  def test_execute_not_implemented
    assert_raises(Yorishiro::SkillNotImplementedError) { Yorishiro::Skill.new.execute({}) }
  end
end
