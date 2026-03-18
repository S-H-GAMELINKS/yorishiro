# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestWriteFile < Minitest::Test
  def setup
    @tool = Yorishiro::Tools::WriteFile.new
  end

  def test_name
    assert_equal "write_file", @tool.name
  end

  def test_permission_check_always_asks
    assert_equal :ask, @tool.permission_check({})
  end

  def test_execute_writes_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "output.txt")
      result = @tool.execute(path: path, content: "hello world")
      assert_includes result, "Successfully wrote"
      assert_equal "hello world", File.read(path)
    end
  end

  def test_execute_creates_directories
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sub", "dir", "output.txt")
      @tool.execute(path: path, content: "nested")
      assert_equal "nested", File.read(path)
    end
  end

  def test_execute_overwrites_existing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "output.txt")
      File.write(path, "old content")
      @tool.execute(path: path, content: "new content")
      assert_equal "new content", File.read(path)
    end
  end
end
