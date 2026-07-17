# frozen_string_literal: true

module Yorishiro
  module Provider
    class Ollama < Base
      DEFAULT_BASE_URL = "http://localhost:11434"
      DEFAULT_NUM_CTX = 8192
      OUTPUT_TOKEN_RESERVE = 2048
      MIN_CONTEXT_BUDGET = 1024

      def initialize(api_key: nil, model: nil, base_url: nil, num_ctx: nil)
        @base_url = base_url || ENV.fetch("OLLAMA_HOST", DEFAULT_BASE_URL)
        @num_ctx = num_ctx
        super(api_key: api_key || "unused", model: model)
      end

      def self.supported_models
        base_url = ENV.fetch("OLLAMA_HOST", DEFAULT_BASE_URL)
        uri = URI("#{base_url}/api/tags")
        response = Net::HTTP.get_response(uri)
        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body)
        data.fetch("models", []).map { |m| m["name"] }
      rescue StandardError
        []
      end

      def chat(conversation, tools: [], &)
        uri = URI("#{@base_url}/api/chat")

        body = {
          model: @model_name,
          messages: format_messages(conversation.to_api_messages),
          keep_alive: ENV.fetch("OLLAMA_KEEP_ALIVE", "10m"),
          options: { num_ctx: num_ctx },
          stream: true
        }

        headers = { "Content-Type" => "application/json" }

        body[:tools] = format_tools(tools) unless tools.empty?

        debug_log("Ollama request", body)

        @last_meta = {}
        result = post_stream(uri, headers: headers, body: body, &)
        result[:meta] = @last_meta
        result[:usage] = { input: @last_meta[:prompt_eval_count], output: @last_meta[:eval_count] }
        debug_log("Ollama response", result)
        result
      end

      # Token budget the conversation should be trimmed to before each request.
      # Reserves headroom for the model's output within the configured context window.
      def context_budget_tokens
        [num_ctx - OUTPUT_TOKEN_RESERVE, MIN_CONTEXT_BUDGET].max
      end

      private

      # Resolve the Ollama context window (num_ctx). Priority:
      #   1. explicit value from .yorishirorc (constructor argument)
      #   2. OLLAMA_NUM_CTX environment variable
      #   3. DEFAULT_NUM_CTX
      def num_ctx
        return @num_ctx.to_i if @num_ctx

        env = ENV.fetch("OLLAMA_NUM_CTX", nil)
        return env.to_i if env && !env.empty?

        DEFAULT_NUM_CTX
      end

      def default_model
        "llama3.1"
      end

      def read_timeout
        nil # local inference (prompt eval on large inputs) can take arbitrarily long
      end

      def format_messages(api_messages)
        api_messages.map do |msg|
          if msg[:role] == "tool"
            { role: "tool", content: msg[:content] }
          elsif msg[:tool_calls]&.any?
            formatted = { role: "assistant" }
            formatted[:content] = msg[:content] if msg[:content] && !msg[:content].empty?
            formatted[:tool_calls] = msg[:tool_calls].map do |tc|
              {
                function: {
                  name: tc[:name],
                  arguments: tc[:arguments]
                }
              }
            end
            formatted
          else
            { role: msg[:role], content: msg[:content] }
          end
        end
      end

      def format_tools(tools)
        tools.map do |t|
          {
            type: "function",
            function: {
              name: t[:name],
              description: t[:description],
              parameters: t[:input_schema]
            }
          }
        end
      end

      def parse_stream(response, tool_calls:, &block)
        buffer = +""

        response.read_body do |chunk|
          buffer << chunk
          while (idx = buffer.index("\n"))
            line = buffer.slice!(0, idx + 1).strip
            next if line.empty?

            data = parse_ndjson_line(line)
            next unless data

            raise ProviderError, "Ollama error: #{data["error"]}" if data["error"]

            capture_meta(data)

            message = data["message"]
            next unless message

            block&.call(message["content"]) if message["content"] && !message["content"].empty?

            next unless message["tool_calls"]

            message["tool_calls"].each do |tc|
              func = tc["function"]
              next unless func

              tool_calls << {
                id: "ollama_#{SecureRandom.hex(8)}",
                name: func["name"],
                arguments: func["arguments"].is_a?(Hash) ? func["arguments"] : JSON.parse(func["arguments"].to_s)
              }
            end
          end
        end
      end

      # Parse a single NDJSON line, skipping (rather than crashing on) malformed
      # or partial lines that Ollama can emit under load or on unexpected output.
      def parse_ndjson_line(line)
        JSON.parse(line)
      rescue JSON::ParserError => e
        debug_log("Ollama: skipping malformed NDJSON line", e.message)
        nil
      end

      # Capture the final-chunk stats so the CLI can detect context truncation
      # (prompt_eval_count approaching num_ctx) and empty responses.
      def capture_meta(data)
        return unless data["done"]

        @last_meta ||= {}
        %w[done_reason prompt_eval_count eval_count].each do |key|
          @last_meta[key.to_sym] = data[key] if data.key?(key)
        end
      end
    end
  end
end
