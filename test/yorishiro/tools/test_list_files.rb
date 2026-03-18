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
end
