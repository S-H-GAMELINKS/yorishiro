# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestSkillLoader < Minitest::Test
  def setup
    @config = Yorishiro::Configuration.new
    @loader = Yorishiro::SkillLoader.new(@config)
  end

  # NOTE: each test uses globally unique class names — `load` reopens an
  # already-defined class, so the subclass diff would come up empty for a
  # reused name within the same test process.

  def test_load_dir_missing_is_noop
    @loader.load_dir("/nonexistent/skills")

    assert_empty @config.skills
  end

  def test_loads_and_registers_skill_classes
    Dir.mktmpdir do |dir|
      write_skill(dir, "greet.rb", "LoaderGreetSkill", "loader_greet", "hello!")

      @loader.load_dir(dir)

      skill = @config.skills.find { |s| s.name == "loader_greet" }
      refute_nil skill
      assert_equal "hello!", skill.execute({})
    end
  end

  def test_registers_multiple_skills_in_one_file
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "multi.rb"), <<~RUBY)
        class LoaderMultiOneSkill < Yorishiro::Skill
          def name = "loader_multi_one"
          def description = "one"
          def execute(_context) = "one"
        end

        class LoaderMultiTwoSkill < Yorishiro::Skill
          def name = "loader_multi_two"
          def description = "two"
          def execute(_context) = "two"
        end
      RUBY

      @loader.load_dir(dir)

      names = @config.skills.map(&:name)
      assert_includes names, "loader_multi_one"
      assert_includes names, "loader_multi_two"
    end
  end

  def test_ignores_non_skill_classes
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "helper.rb"), <<~RUBY)
        class LoaderPlainHelper
          def name = "not_a_skill"
        end
      RUBY

      @loader.load_dir(dir)

      assert_empty @config.skills
    end
  end

  def test_skips_abstract_intermediate_classes
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "layered.rb"), <<~RUBY)
        class LoaderAbstractBaseSkill < Yorishiro::Skill
          def description = "shared base"
        end

        class LoaderConcreteChildSkill < LoaderAbstractBaseSkill
          def name = "loader_concrete_child"
          def execute(_context) = "child"
        end
      RUBY

      @loader.load_dir(dir)

      names = @config.skills.map(&:name)
      assert_equal ["loader_concrete_child"], names
    end
  end

  def test_replaces_same_name_skill_from_later_directory
    Dir.mktmpdir do |global_dir|
      Dir.mktmpdir do |local_dir|
        write_skill(global_dir, "dup.rb", "LoaderGlobalDupSkill", "loader_dup", "from global")
        write_skill(local_dir, "dup.rb", "LoaderLocalDupSkill", "loader_dup", "from local")

        @loader.load_dir(global_dir)
        @loader.load_dir(local_dir)

        dups = @config.skills.select { |s| s.name == "loader_dup" }
        assert_equal 1, dups.length
        assert_equal "from local", dups.first.execute({})
      end
    end
  end

  def test_syntax_error_raises_configuration_error_with_path
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.rb")
      File.write(path, "class LoaderBrokenSkill < Yorishiro::Skill\n  def name = ")

      error = assert_raises(Yorishiro::ConfigurationError) { @loader.load_dir(dir) }

      assert_includes error.message, path
    end
  end

  def test_initializer_with_required_args_raises_configuration_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "needy.rb")
      File.write(path, <<~RUBY)
        class LoaderNeedySkill < Yorishiro::Skill
          def initialize(required_arg)
            super()
            @required_arg = required_arg
          end

          def name = "loader_needy"
          def description = "needs an argument"
          def execute(_context) = @required_arg
        end
      RUBY

      error = assert_raises(Yorishiro::ConfigurationError) { @loader.load_dir(dir) }

      assert_includes error.message, "LoaderNeedySkill"
      assert_includes error.message, path
    end
  end

  private

  def write_skill(dir, filename, class_name, skill_name, output)
    File.write(File.join(dir, filename), <<~RUBY)
      class #{class_name} < Yorishiro::Skill
        def name = "#{skill_name}"
        def description = "test skill"
        def execute(_context) = "#{output}"
      end
    RUBY
  end
end
