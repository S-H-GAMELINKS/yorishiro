# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestReadFile < Minitest::Test
  def setup
    @tool = Yorishiro::Tools::ReadFile.new
  end

  def test_name
    assert_equal "read_file", @tool.name
  end

  def test_description
    refute_nil @tool.description
  end

  def test_parameters
    params = @tool.parameters
    assert_equal "object", params[:type]
    assert_includes params[:required], "path"
  end

  def test_definition
    defn = @tool.definition
    assert_equal "read_file", defn[:name]
    assert defn[:description]
    assert defn[:input_schema]
  end

  def test_read_only
    assert @tool.read_only?
  end

  def test_permission_check
    assert_equal :allowed, @tool.permission_check({})
  end

  def test_execute_reads_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.txt")
      File.write(path, "line 1\nline 2\nline 3\n")

      result = @tool.execute(path: path)
      assert_includes result, "line 1"
      assert_includes result, "line 2"
      assert_includes result, "line 3"
    end
  end

  def test_execute_with_offset_and_limit
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.txt")
      File.write(path, "line 1\nline 2\nline 3\nline 4\n")

      result = @tool.execute(path: path, offset: 1, limit: 2)
      assert_includes result, "line 2"
      assert_includes result, "line 3"
      refute_includes result, "line 1"
      refute_includes result, "line 4"
    end
  end

  def test_execute_file_not_found
    assert_raises(RuntimeError) { @tool.execute(path: "/nonexistent/file.txt") }
  end

  def test_execute_small_file_has_no_paging_notice
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.txt")
      File.write(path, "line 1\nline 2\n")

      result = @tool.execute(path: path)
      refute_includes result, "Use offset/limit"
    end
  end

  def test_execute_caps_lines_by_default_with_paging_notice
    Dir.mktmpdir do |dir|
      path = File.join(dir, "big.txt")
      File.write(path, (1..300).map { |i| "line #{i}" }.join("\n"))

      result = @tool.execute(path: path)

      assert_includes result, "200: line 200"
      refute_includes result, "line 201"
      assert_includes result, "file has 300 lines; showing 1-200"
      assert_includes result, "Use offset/limit"
    end
  end

  def test_execute_clamps_explicit_limit_to_max_lines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "big.txt")
      File.write(path, (1..300).map { |i| "line #{i}" }.join("\n"))

      result = @tool.execute(path: path, limit: 5000)

      refute_includes result, "line 201"
      assert_includes result, "file has 300 lines"
    end
  end

  def test_execute_pages_with_offset
    Dir.mktmpdir do |dir|
      path = File.join(dir, "big.txt")
      File.write(path, (1..300).map { |i| "line #{i}" }.join("\n"))

      result = @tool.execute(path: path, offset: 200)

      assert_includes result, "201: line 201"
      assert_includes result, "300: line 300"
      refute_includes result, "Use offset/limit" # last page, nothing left
    end
  end

  def test_execute_truncates_very_long_lines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "wide.txt")
      File.write(path, "short\n#{"x" * 900}\n")

      result = @tool.execute(path: path)

      assert_includes result, "(line truncated)"
      refute_includes result, "x" * 501
    end
  end
end
