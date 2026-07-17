# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Yorishiro
  module Provider
    class Base
      attr_reader :api_key, :model_name

      def initialize(api_key:, model: nil)
        @api_key = api_key
        @model_name = model || default_model
      end

      def chat(_conversation, tools: [], &) # rubocop:disable Lint/UnusedMethodArgument
        raise ProviderNotImplementedError, "#{self.class}#chat is not implemented"
      end

      def self.supported_models
        raise ProviderNotImplementedError, "#{self}.supported_models is not implemented"
      end

      def debug?
        ENV["YORISHIRO_DEBUG"] == "1"
      end

      def debug_log(label, data = nil)
        return unless debug?

        warn "[DEBUG] #{label}"
        warn(data.is_a?(String) ? data : JSON.pretty_generate(data)) if data
      rescue StandardError
        nil
      end

      # Token budget the conversation should be trimmed to before each request.
      # nil means "no known context window" — the conversation is not trimmed.
      # Providers with a fixed local context window (Ollama) override this.
      def context_budget_tokens
        nil
      end

      private

      def default_model
        raise ProviderNotImplementedError, "#{self.class}#default_model is not implemented"
      end

      def read_timeout
        120
      end

      def post_stream(uri, headers:, body:, &block)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.read_timeout = read_timeout

        request = Net::HTTP::Post.new(uri)
        headers.each { |k, v| request[k] = v }
        request.body = JSON.generate(body)

        full_response = +""
        tool_calls = []

        http.request(request) do |response|
          handle_error_response!(response) unless response.is_a?(Net::HTTPSuccess)

          parse_stream(response, tool_calls: tool_calls) do |text|
            full_response << text
            block&.call(text)
          end
        end

        { content: full_response, tool_calls: tool_calls }
      end

      def parse_stream(_response, tool_calls:, &) # rubocop:disable Lint/UnusedMethodArgument
        raise ProviderNotImplementedError, "#{self.class}#parse_stream is not implemented"
      end

      def handle_error_response!(response)
        case response.code.to_i
        when 401
          raise ProviderError, "Authentication failed (401). Check your API key."
        when 429
          raise ProviderError, "Rate limit exceeded (429). Please wait and try again."
        else
          raise ProviderError, "API error (#{response.code}): #{response.body}"
        end
      end

      def parse_sse_event(event_str)
        data = nil
        event_type = nil

        event_str.each_line do |line|
          line = line.strip
          if line.start_with?("event:")
            event_type = line.sub("event:", "").strip
          elsif line.start_with?("data:")
            raw = line.sub("data:", "").strip
            next if raw == "[DONE]"

            data = JSON.parse(raw)
          end
        end

        { event: event_type, data: data }
      end
    end

    def self.for(provider_name)
      case provider_name
      when :anthropic
        Anthropic
      when :open_ai
        OpenAI
      when :ollama
        Ollama
      else
        raise ProviderNotImplementedError, "Unknown provider: #{provider_name}"
      end
    end

    def self.build(config)
      provider_class = self.for(config.provider_name)

      if config.provider_name == :ollama
        provider_class.new(api_key: config.api_key, model: config.model, num_ctx: config.ollama_num_ctx_value)
      else
        provider_class.new(api_key: config.api_key, model: config.model)
      end
    end
  end
end
