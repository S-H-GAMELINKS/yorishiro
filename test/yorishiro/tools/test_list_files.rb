# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestListFiles < Minitest::Test
  def setup
    @tool = Yorishiro::Tools::ListFiles.new
  end

  def test_name
    assert_equal "list_files", @tool.name
  end

  def test_read_only
    assert @tool.read_only?
  end

  def test_permission_check
    assert_equal :allowed, @tool.permission_check({})
  end

  def test_execute_lists_directory
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "")
      File.write(File.join(dir, "b.rb"), "")

      result = @tool.execute(path: dir)
      assert_includes result, "a.txt"
      assert_includes result, "b.rb"
    end
  end

  def test_execute_with_pattern
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "")
      File.write(File.join(dir, "b.rb"), "")

      result = @tool.execute(path: dir, pattern: "*.rb")
      assert_includes result, "b.rb"
      refute_includes result, "a.txt"
    end
  end

  def test_execute_directory_not_found
    assert_raises(RuntimeError) { @tool.execute(path: "/nonexistent/dir") }
  end

  def test_execute_marks_directories_outside_the_cwd
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, "sub"))
      File.write(File.join(dir, "plain.txt"), "")

      # The tool must resolve entries against the listed path, not the
      # process cwd — "sub" does not exist relative to the test runner's cwd.
      result = @tool.execute(path: dir).lines(chomp: true)
      assert_includes result, "sub/"
      assert_includes result, "plain.txt"
    end
  end

  def test_execute_with_pattern_marks_directories
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, "sub"))
      File.write(File.join(dir, "plain.txt"), "")

      result = @tool.execute(path: dir, pattern: "*").lines(chomp: true)
      assert_includes result, "#{File.join(dir, "sub")}/"
      assert_includes result, File.join(dir, "plain.txt")
    end
  end
end
