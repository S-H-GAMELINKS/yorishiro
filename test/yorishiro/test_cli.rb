# frozen_string_literal: true

require "test_helper"

class TestCLI < Minitest::Test
  class FakeTool < Yorishiro::Tool
    def name = "write_file"
    def description = "Write a file"
    def parameters = { type: "object" }
  end

  def setup
    @output = StringIO.new
    @cli = Yorishiro::CLI.new
    @cli.instance_variable_set(:@output, @output)
  end

  def test_ask_permission_short_args
    tool = FakeTool.new
    tool_call = { arguments: { "path" => "test.rb", "mode" => "write" } }

    simulate_input("y") do
      result = @cli.send(:ask_permission, tool, tool_call)
      assert_equal :allowed, result
    end

    output = @output.string
    assert_includes output, "[Permission] write_file"
    assert_includes output, "  path: test.rb"
    assert_includes output, "  mode: write"
  end

  def test_ask_permission_long_content_multiline
    tool = FakeTool.new
    content = "puts \"Hello, World!\"\nputs \"This is a test.\"\nputs \"Line three.\""
    tool_call = { arguments: { "path" => "test.rb", "content" => content } }

    simulate_input("y") do
      @cli.send(:ask_permission, tool, tool_call)
    end

    output = @output.string
    assert_includes output, "[Permission] write_file"
    assert_includes output, "  path: test.rb"
    assert_includes output, "  content:"
    assert_includes output, "    puts \"Hello, World!\""
    assert_includes output, "    puts \"This is a test.\""
  end

  def test_ask_permission_long_single_line_content
    tool = FakeTool.new
    content = "a" * 100
    tool_call = { arguments: { "path" => "test.rb", "content" => content } }

    simulate_input("y") do
      @cli.send(:ask_permission, tool, tool_call)
    end

    output = @output.string
    assert_includes output, "  content:"
    assert_includes output, "    #{"a" * 100}"
  end

  def test_ask_permission_truncates_very_long_content
    tool = FakeTool.new
    content = "x" * 600
    tool_call = { arguments: { "content" => content } }

    simulate_input("y") do
      @cli.send(:ask_permission, tool, tool_call)
    end

    output = @output.string
    assert_includes output, "  content:"
    assert_includes output, "x" * 500
    assert_includes output, "..."
  end

  def test_ask_permission_deny
    tool = FakeTool.new
    tool_call = { arguments: { "path" => "test.rb" } }

    simulate_input("n") do
      result = @cli.send(:ask_permission, tool, tool_call)
      assert_equal :denied, result
    end
  end

  def test_ask_permission_nil_arguments
    tool = FakeTool.new
    tool_call = { arguments: nil }

    simulate_input("y") do
      result = @cli.send(:ask_permission, tool, tool_call)
      assert_equal :allowed, result
    end

    output = @output.string
    assert_includes output, "[Permission] write_file"
  end

  private

  def simulate_input(text)
    old_stdin = $stdin
    $stdin = StringIO.new(text)
    # Reline.readline receives (prompt, add_hist) — return the simulated text
    fake_readline = ->(_prompt, _add_hist = false) { text }
    Reline.stub(:readline, fake_readline) do
      yield
    end
  ensure
    $stdin = old_stdin
  end
end
