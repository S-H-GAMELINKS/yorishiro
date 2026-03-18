# frozen_string_literal: true

require "test_helper"

class TestExecuteCommand < Minitest::Test
  def setup
    @tool = Yorishiro::Tools::ExecuteCommand.new
  end

  def test_name
    assert_equal "execute_command", @tool.name
  end

  def test_default_permission_check_asks
    assert_equal :ask, @tool.permission_check(command: "rm -rf /")
  end

  def test_execute_runs_command
    result = @tool.execute(command: "echo hello")
    assert_includes result, "hello"
    assert_includes result, "Exit code: 0"
  end

  def test_execute_captures_stderr
    result = @tool.execute(command: "echo error >&2")
    assert_includes result, "STDERR: error"
  end

  def test_execute_returns_exit_code
    result = @tool.execute(command: "exit 1")
    assert_includes result, "Exit code: 1"
  end

  def test_configure_allow_commands
    @tool.configure(allow_commands: ["ls", "git *"])
    assert_equal :allowed, @tool.permission_check(command: "ls")
    assert_equal :allowed, @tool.permission_check(command: "git status")
    assert_equal :ask, @tool.permission_check(command: "rm -rf /")
  end

  def test_session_allow
    assert_equal :ask, @tool.permission_check(command: "npm test")
    @tool.session_allow!("npm test")
    assert_equal :allowed, @tool.permission_check(command: "npm test")
  end

  def test_glob_pattern_matching
    @tool.configure(allow_commands: ["bundle exec *"])
    assert_equal :allowed, @tool.permission_check(command: "bundle exec rake test")
    assert_equal :ask, @tool.permission_check(command: "bundle install")
  end
end
