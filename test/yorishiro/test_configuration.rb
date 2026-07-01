# frozen_string_literal: true

require "test_helper"

class TestConfiguration < Minitest::Test
  def setup
    Yorishiro.reset!
    @config = Yorishiro::Configuration.new
  end

  def test_use_sets_provider
    @config.use(provider: :anthropic, api_key: "test-key", model: "claude-sonnet-4-20250514")
    assert_equal :anthropic, @config.provider_name
    assert_equal "test-key", @config.api_key
    assert_equal "claude-sonnet-4-20250514", @config.model
  end

  def test_use_with_open_ai
    @config.use(provider: :open_ai, api_key: "sk-test")
    assert_equal :open_ai, @config.provider_name
  end

  def test_use_with_ollama
    @config.use(provider: :ollama)
    assert_nil @config.api_key
  end

  def test_allow_tool
    tool = Yorishiro::Tools::ReadFile.new
    @config.allow_tool(tool)
    assert_includes @config.allowed_tools, tool
  end

  def test_allow_tool_with_options
    tool = Yorishiro::Tools::ExecuteCommand.new
    @config.allow_tool(tool, allow_commands: ["ls", "git *"])
    assert_includes @config.allowed_tools, tool
  end

  def test_skill_registration
    skill = Class.new(Yorishiro::Skill) do
      def name = "test_skill"
      def description = "A test skill"
      def execute(_context) = "done"
    end.new

    @config.skill(skill)
    assert_includes @config.skills, skill
  end

  def test_skill_validation
    invalid_skill = Object.new
    assert_raises(Yorishiro::SkillNotImplementedError) { @config.skill(invalid_skill) }
  end

  def test_mcp_server
    @config.mcp_server("test", command: "echo", args: ["hello"])
    assert_equal({ command: "echo", args: ["hello"], env: {} }, @config.mcp_servers["test"])
  end

  def test_system_prompt
    @config.system_prompt("You are helpful.")
    assert_equal "You are helpful.", @config.system_prompt_text
  end

  def test_plan_mode
    @config.plan_mode(true)
    assert @config.plan_mode_enabled
  end

  def test_ollama_num_ctx_default_nil
    assert_nil @config.ollama_num_ctx_value
  end

  def test_ollama_num_ctx_setter
    @config.ollama_num_ctx(16_384)
    assert_equal 16_384, @config.ollama_num_ctx_value
  end

  def test_auto_compact_default_true
    assert @config.auto_compact_enabled
  end

  def test_auto_compact_setter
    @config.auto_compact(false)
    refute @config.auto_compact_enabled
  end

  def test_ollama_num_ctx_passed_to_provider
    @config.use(provider: :ollama)
    @config.ollama_num_ctx(4096)

    provider = Yorishiro::Provider.build(@config)
    assert_instance_of Yorishiro::Provider::Ollama, provider
    # num_ctx flows through to the request options.
    assert_equal 2048, provider.context_budget_tokens # 4096 - 2048 reserve
  end

  def test_validate_missing_provider
    assert_raises(Yorishiro::ConfigurationError) { @config.validate! }
  end

  def test_validate_unsupported_provider
    @config.use(provider: :unknown, api_key: "key")
    assert_raises(Yorishiro::ConfigurationError) { @config.validate! }
  end

  def test_validate_missing_api_key
    @config.use(provider: :anthropic)
    assert_raises(Yorishiro::ConfigurationError) { @config.validate! }
  end

  def test_validate_ollama_without_api_key
    @config.use(provider: :ollama)
    @config.validate!
    assert_equal :ollama, @config.provider_name
  end

  def test_validate_unsupported_model
    @config.use(provider: :anthropic, api_key: "test-key", model: "invalid-model")
    assert_raises(Yorishiro::ConfigurationError) { @config.validate! }
  end

  def test_validate_supported_model
    @config.use(provider: :anthropic, api_key: "test-key", model: "claude-sonnet-4-20250514")
    @config.validate!
    assert_equal "claude-sonnet-4-20250514", @config.model
  end

  def test_find_tool
    tool = Yorishiro::Tools::ReadFile.new
    @config.allow_tool(tool)
    assert_equal tool, @config.find_tool("read_file")
    assert_nil @config.find_tool("nonexistent")
  end

  def test_tool_definitions
    @config.allow_tool(Yorishiro::Tools::ReadFile.new)
    @config.allow_tool(Yorishiro::Tools::ListFiles.new)
    defs = @config.tool_definitions
    assert_equal 2, defs.length
    assert_equal "read_file", defs[0][:name]
    assert_equal "list_files", defs[1][:name]
  end

  def test_read_only_tool_definitions
    @config.allow_tool(Yorishiro::Tools::ReadFile.new)
    @config.allow_tool(Yorishiro::Tools::ListFiles.new)
    @config.allow_tool(Yorishiro::Tools::WriteFile.new)
    @config.allow_tool(Yorishiro::Tools::ExecuteCommand.new)
    defs = @config.read_only_tool_definitions
    assert_equal 2, defs.length
    names = defs.map { |d| d[:name] }
    assert_includes names, "read_file"
    assert_includes names, "list_files"
    refute_includes names, "write_file"
    refute_includes names, "execute_command"
  end

  def test_load_rc_file
    Dir.mktmpdir do |dir|
      rc_path = File.join(dir, ".yorishirorc")
      File.write(rc_path, <<~RC)
        use provider: :anthropic, api_key: "test-from-rc"
      RC

      @config.stub(:global_rc_path, rc_path) do
        @config.stub(:local_rc_path, "/nonexistent") do
          @config.load!
        end
      end

      assert_equal :anthropic, @config.provider_name
      assert_equal "test-from-rc", @config.api_key
    end
  end

  def test_local_rc_overrides_global
    Dir.mktmpdir do |dir|
      global_rc = File.join(dir, ".yorishirorc")
      local_rc = File.join(dir, ".lyorishirorc")

      File.write(global_rc, <<~RC)
        use provider: :anthropic, api_key: "global-key", model: "claude-sonnet-4-20250514"
      RC
      File.write(local_rc, <<~RC)
        use provider: :anthropic, api_key: "local-key", model: "claude-sonnet-4-20250514"
      RC

      @config.stub(:global_rc_path, global_rc) do
        @config.stub(:local_rc_path, local_rc) do
          @config.load!
        end
      end

      assert_equal "local-key", @config.api_key
    end
  end
end
