# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

require_relative "yorishiro/version"
require_relative "yorishiro/tool"
require_relative "yorishiro/skill"
require_relative "yorishiro/configuration"
require_relative "yorishiro/conversation"
require_relative "yorishiro/input_history"
require_relative "yorishiro/session_store"
require_relative "yorishiro/session_resume"
require_relative "yorishiro/compactor"
require_relative "yorishiro/provider/base"
require_relative "yorishiro/provider/anthropic"
require_relative "yorishiro/provider/open_ai"
require_relative "yorishiro/provider/ollama"
require_relative "yorishiro/tools/read_file"
require_relative "yorishiro/tools/write_file"
require_relative "yorishiro/tools/list_files"
require_relative "yorishiro/tools/execute_command"
require_relative "yorishiro/mcp/tool"
require_relative "yorishiro/mcp/server_manager"
require_relative "yorishiro/cli"

module Yorishiro
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ProviderError < Error; end
  class ProviderNotImplementedError < Error; end
  class ToolNotImplementedError < Error; end
  class SkillNotImplementedError < Error; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def provider
      @provider ||= Provider.build(configuration)
    end

    def reset!
      @configuration = nil
      @provider = nil
    end
  end
end
