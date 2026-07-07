# frozen_string_literal: true

require "test_helper"

class TestHooks < Minitest::Test
  def setup
    @hooks = Yorishiro::Hooks.new
  end

  def test_on_unknown_event_raises
    error = assert_raises(Yorishiro::ConfigurationError) { @hooks.on(:no_such_event) { nil } }

    assert_includes error.message, "Unknown hook event"
  end

  def test_any
    refute @hooks.any?(:before_tool_use)

    @hooks.on(:before_tool_use) { nil }

    assert @hooks.any?(:before_tool_use)
  end

  def test_run_before_tool_use_without_hooks_proceeds
    assert_nil @hooks.run_before_tool_use("write_file", {})
  end

  def test_run_before_tool_use_nil_return_proceeds
    # A logging hook returns nil (puts and friends) — that must not deny.
    @hooks.on(:before_tool_use) { nil }

    assert_nil @hooks.run_before_tool_use("write_file", {})
  end

  def test_run_before_tool_use_deny_symbol
    @hooks.on(:before_tool_use) { :deny }

    denial = @hooks.run_before_tool_use("write_file", {})

    assert_instance_of Yorishiro::Hooks::Denial, denial
    assert_equal "denied by hook", denial.reason
  end

  def test_run_before_tool_use_denial_with_reason
    @hooks.on(:before_tool_use) do |tool_name, args|
      Yorishiro::Hooks::Denial.new("no rm") if tool_name == "execute_command" && args["command"].include?("rm")
    end

    denial = @hooks.run_before_tool_use("execute_command", { "command" => "rm -rf /" })

    assert_equal "no rm", denial.reason
    assert_nil @hooks.run_before_tool_use("execute_command", { "command" => "ls" })
  end

  def test_run_before_tool_use_first_denial_wins
    @hooks.on(:before_tool_use) { Yorishiro::Hooks::Denial.new("first") }
    @hooks.on(:before_tool_use) { Yorishiro::Hooks::Denial.new("second") }

    assert_equal "first", @hooks.run_before_tool_use("write_file", {}).reason
  end

  def test_run_before_tool_use_exception_fails_closed
    @hooks.on(:before_tool_use) { raise "guard broke" }

    denial = @hooks.run_before_tool_use("write_file", {})

    assert_instance_of Yorishiro::Hooks::Denial, denial
    assert_includes denial.reason, "guard broke"
  end

  def test_run_user_prompt_submit_deny
    @hooks.on(:user_prompt_submit) { |input| Yorishiro::Hooks::Denial.new("secret") if input.include?("password") }

    assert_equal "secret", @hooks.run_user_prompt_submit("my password is hunter2").reason
    assert_nil @hooks.run_user_prompt_submit("hello")
  end

  def test_run_after_tool_use_receives_arguments
    received = nil
    @hooks.on(:after_tool_use) { |name, args, result| received = [name, args, result] }

    @hooks.run_after_tool_use("read_file", { "path" => "a.txt" }, "contents")

    assert_equal ["read_file", { "path" => "a.txt" }, "contents"], received
  end

  def test_run_after_tool_use_exception_propagates
    @hooks.on(:after_tool_use) { raise "observer broke" }

    assert_raises(RuntimeError) { @hooks.run_after_tool_use("read_file", {}, "x") }
  end
end
