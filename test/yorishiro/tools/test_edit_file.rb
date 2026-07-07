# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestEditFile < Minitest::Test
  def setup
    @tool = Yorishiro::Tools::EditFile.new
  end

  def test_name
    assert_equal "edit_file", @tool.name
  end

  def test_not_read_only
    refute @tool.read_only?
  end

  def test_permission_check_always_asks
    assert_equal :ask, @tool.permission_check({})
  end

  def test_definition
    definition = @tool.definition

    assert_equal "edit_file", definition[:name]
    assert_equal %w[path old_string new_string], definition[:input_schema][:required]
  end

  def test_execute_replaces_unique_string
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "def foo\n  1\nend\n")

      result = @tool.execute(path: path, old_string: "  1", new_string: "  2")

      assert_includes result, "Successfully replaced 1 occurrence(s)"
      assert_equal "def foo\n  2\nend\n", File.read(path)
    end
  end

  def test_execute_old_string_not_found
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "content\n")

      error = assert_raises(RuntimeError) { @tool.execute(path: path, old_string: "missing", new_string: "x") }

      assert_includes error.message, "not found"
      assert_includes error.message, "Read the file first"
      assert_equal "content\n", File.read(path)
    end
  end

  def test_execute_ambiguous_old_string
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "dup\ndup\n")

      error = assert_raises(RuntimeError) { @tool.execute(path: path, old_string: "dup", new_string: "x") }

      assert_includes error.message, "2 times"
      assert_includes error.message, "replace_all"
      assert_equal "dup\ndup\n", File.read(path)
    end
  end

  def test_execute_replace_all
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "dup\ndup\nother\n")

      result = @tool.execute(path: path, old_string: "dup", new_string: "x", replace_all: true)

      assert_includes result, "Successfully replaced 2 occurrence(s)"
      assert_equal "x\nx\nother\n", File.read(path)
    end
  end

  def test_execute_writes_backslashes_literally
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "placeholder\n")

      @tool.execute(path: path, old_string: "placeholder", new_string: "gsub(/x/, \"\\\\1\")")

      assert_equal "gsub(/x/, \"\\\\1\")\n", File.read(path)
    end
  end

  def test_execute_identical_strings
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "same\n")

      error = assert_raises(RuntimeError) { @tool.execute(path: path, old_string: "same", new_string: "same") }

      assert_includes error.message, "identical"
    end
  end

  def test_execute_file_not_found
    error = assert_raises(RuntimeError) { @tool.execute(path: "/nonexistent/a.rb", old_string: "a", new_string: "b") }

    assert_includes error.message, "File not found"
  end

  def test_execute_with_string_keys
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "old\n")

      @tool.execute("path" => path, "old_string" => "old", "new_string" => "new")

      assert_equal "new\n", File.read(path)
    end
  end

  def test_preview_returns_diff
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "line 1\nline 2\n")

      preview = @tool.preview(path: path, old_string: "line 2", new_string: "line two")

      assert_includes preview, "-line 2"
      assert_includes preview, "+line two"
      assert_equal "line 1\nline 2\n", File.read(path) # preview must not modify the file
    end
  end

  def test_preview_returns_nil_when_old_string_missing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "content\n")

      assert_nil @tool.preview(path: path, old_string: "missing", new_string: "x")
    end
  end

  def test_preview_returns_nil_for_missing_file
    assert_nil @tool.preview(path: "/nonexistent/a.rb", old_string: "a", new_string: "b")
  end
end
