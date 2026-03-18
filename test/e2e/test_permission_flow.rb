# frozen_string_literal: true

require_relative "test_helper"

class TestPermissionFlow < Minitest::Test
  def setup
    Yorishiro.reset!
  end

  def test_allowed_command_pattern
    tool = Yorishiro::Tools::ExecuteCommand.new
    tool.configure(allow_commands: ["echo *"])

    assert_equal :allowed, tool.permission_check(command: "echo hello")
    assert_equal :ask, tool.permission_check(command: "rm -rf /")
  end

  def test_session_allow_persists
    tool = Yorishiro::Tools::ExecuteCommand.new

    assert_equal :ask, tool.permission_check(command: "npm test")
    tool.session_allow!("npm test")
    assert_equal :allowed, tool.permission_check(command: "npm test")
    # Other commands still ask
    assert_equal :ask, tool.permission_check(command: "npm install")
  end

  def test_write_file_always_asks
    tool = Yorishiro::Tools::WriteFile.new
    assert_equal :ask, tool.permission_check(path: "/tmp/test", content: "data")
  end

  def test_read_file_always_allowed
    tool = Yorishiro::Tools::ReadFile.new
    assert_equal :allowed, tool.permission_check(path: "/tmp/test")
  end

  def test_list_files_always_allowed
    tool = Yorishiro::Tools::ListFiles.new
    assert_equal :allowed, tool.permission_check(path: "/tmp")
  end

  def test_multiple_patterns
    tool = Yorishiro::Tools::ExecuteCommand.new
    tool.configure(allow_commands: ["ls", "git *", "bundle exec *"])

    assert_equal :allowed, tool.permission_check(command: "ls")
    assert_equal :allowed, tool.permission_check(command: "git status")
    assert_equal :allowed, tool.permission_check(command: "git push origin main")
    assert_equal :allowed, tool.permission_check(command: "bundle exec rake test")
    assert_equal :ask, tool.permission_check(command: "curl http://example.com")
  end
end
