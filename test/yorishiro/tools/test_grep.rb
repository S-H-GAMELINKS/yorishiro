# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestGrep < Minitest::Test
  def setup
    @tool = Yorishiro::Tools::Grep.new
  end

  def test_name
    assert_equal "grep", @tool.name
  end

  def test_read_only
    assert @tool.read_only?
  end

  def test_permission_check
    assert_equal :allowed, @tool.permission_check({})
  end

  def test_definition
    definition = @tool.definition

    assert_equal "grep", definition[:name]
    assert_equal ["pattern"], definition[:input_schema][:required]
  end

  def test_execute_returns_file_line_content_format
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "first line\nsecond line\n")

      result = @tool.execute(pattern: "second", path: dir)

      assert_equal "#{File.join(dir, "a.txt")}:2:second line", result
    end
  end

  def test_execute_supports_regular_expressions
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "def foo\nend\ndef bar\nend\n")

      result = @tool.execute(pattern: "def \\w+", path: dir)

      assert_includes result, "a.rb:1:def foo"
      assert_includes result, "a.rb:3:def bar"
      refute_includes result, ":2:"
    end
  end

  def test_execute_with_glob_filters_files
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "target\n")
      File.write(File.join(dir, "b.txt"), "target\n")

      result = @tool.execute(pattern: "target", path: dir, glob: "*.rb")

      assert_includes result, "a.rb"
      refute_includes result, "b.txt"
    end
  end

  def test_execute_searches_subdirectories
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "nested", "deep"))
      File.write(File.join(dir, "nested", "deep", "a.txt"), "target\n")

      result = @tool.execute(pattern: "target", path: dir)

      assert_includes result, File.join("nested", "deep", "a.txt")
    end
  end

  def test_execute_skips_hidden_directories
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".git"))
      File.write(File.join(dir, ".git", "config"), "target\n")

      result = @tool.execute(pattern: "target", path: dir)

      assert_equal "No matches found for pattern: target", result
    end
  end

  def test_execute_skips_excluded_directories
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "node_modules"))
      File.write(File.join(dir, "node_modules", "a.js"), "target\n")

      result = @tool.execute(pattern: "target", path: dir)

      assert_equal "No matches found for pattern: target", result
    end
  end

  def test_execute_skips_binary_files
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "a.bin"), "target\x00binary")

      result = @tool.execute(pattern: "target", path: dir)

      assert_equal "No matches found for pattern: target", result
    end
  end

  def test_execute_truncates_at_max_results
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), Array.new(150) { |i| "target #{i}" }.join("\n"))

      result = @tool.execute(pattern: "target", path: dir)

      assert_equal Yorishiro::Tools::Grep::MAX_RESULTS, result.lines.grep(/:\d+:target/).length
      assert_includes result, "... (truncated: showing first 100 matches)"
    end
  end

  def test_execute_does_not_report_truncation_at_exactly_max_results
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), Array.new(100) { |i| "target #{i}" }.join("\n"))

      result = @tool.execute(pattern: "target", path: dir)

      refute_includes result, "truncated"
    end
  end

  def test_execute_truncates_long_lines
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "target #{"x" * 300}\n")

      result = @tool.execute(pattern: "target", path: dir)

      assert_operator result.length, :<, 300
      assert_includes result, "..."
    end
  end

  def test_execute_no_matches
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "nothing here\n")

      result = @tool.execute(pattern: "missing", path: dir)

      assert_equal "No matches found for pattern: missing", result
    end
  end

  def test_execute_invalid_regexp
    error = assert_raises(RuntimeError) { @tool.execute(pattern: "[unclosed") }

    assert_includes error.message, "Invalid regular expression"
  end

  def test_execute_handles_invalid_utf8_bytes
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "a.txt"), "caf\xE9 target\n")

      result = @tool.execute(pattern: "target", path: dir)

      assert_includes result, "a.txt:1:"
    end
  end

  def test_execute_directory_not_found
    error = assert_raises(RuntimeError) { @tool.execute(pattern: "x", path: "/nonexistent/dir") }

    assert_includes error.message, "Directory not found"
  end

  def test_execute_with_string_keys
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "target\n")
      File.write(File.join(dir, "b.txt"), "target\n")

      result = @tool.execute("pattern" => "target", "path" => dir, "glob" => "*.rb")

      assert_includes result, "a.rb"
      refute_includes result, "b.txt"
    end
  end
end
