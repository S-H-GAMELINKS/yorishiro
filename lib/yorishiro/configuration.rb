# frozen_string_literal: true

module Yorishiro
  class Configuration
    attr_reader :provider_name, :api_key, :model, :allowed_tools, :skills,
                :mcp_servers, :system_prompt_text, :plan_mode_enabled

    def initialize
      @provider_name = nil
      @api_key = nil
      @model = nil
      @allowed_tools = []
      @skills = []
      @mcp_servers = {}
      @system_prompt_text = nil
      @plan_mode_enabled = false
    end

    def use(provider:, api_key: nil, model: nil)
      @provider_name = provider
      @api_key = api_key
      @model = model
    end

    def allow_tool(tool, **options)
      tool.configure(options) if tool.respond_to?(:configure)
      @allowed_tools << tool
    end

    def skill(skill_instance)
      raise SkillNotImplementedError, "Skill must implement #name" unless skill_instance.respond_to?(:name)
      raise SkillNotImplementedError, "Skill must implement #execute" unless skill_instance.respond_to?(:execute)

      @skills << skill_instance
    end

    def mcp_server(name, command:, args: [], env: {})
      @mcp_servers[name] = { command: command, args: args, env: env }
    end

    def system_prompt(text)
      @system_prompt_text = text
    end

    def plan_mode(enabled)
      @plan_mode_enabled = enabled
    end

    def load!
      load_rc_file(global_rc_path)
      load_rc_file(local_rc_path)
      validate!
    end

    def validate!
      raise ConfigurationError, "Provider is not set. Use `use provider: :provider_name`" unless @provider_name

      raise ConfigurationError, "Unsupported provider: #{@provider_name}" unless %i[anthropic open_ai ollama].include?(@provider_name)

      if @provider_name != :ollama && (@api_key.nil? || @api_key.empty?)
        raise ConfigurationError, "API key is required for #{@provider_name}"
      end

      validate_model! if @model
    end

    def find_tool(name)
      @allowed_tools.find { |t| t.name == name }
    end

    def tool_definitions
      @allowed_tools.map(&:definition)
    end

    def read_only_tool_definitions
      @allowed_tools.select(&:read_only?).map(&:definition)
    end

    private

    def global_rc_path
      File.join(Dir.home, ".yorishirorc")
    end

    def local_rc_path
      File.join(Dir.pwd, ".lyorishirorc")
    end

    def load_rc_file(path)
      return unless File.exist?(path)

      content = File.read(path)
      instance_eval(content, path)
    rescue StandardError => e
      raise ConfigurationError, "Error loading #{path}: #{e.message}"
    end

    def validate_model!
      provider_class = Provider.for(@provider_name)
      supported = provider_class.supported_models

      return if supported.empty?
      return if supported.include?(@model)

      raise ConfigurationError,
            "Unsupported model '#{@model}' for #{@provider_name}. Supported: #{supported.join(", ")}"
    end
  end
end
