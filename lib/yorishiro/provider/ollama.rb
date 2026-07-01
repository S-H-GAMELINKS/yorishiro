# frozen_string_literal: true

module Yorishiro
  module Provider
    class Ollama < Base
      DEFAULT_BASE_URL = "http://localhost:11434"

      def initialize(api_key: nil, model: nil, base_url: nil)
        @base_url = base_url || ENV.fetch("OLLAMA_HOST", DEFAULT_BASE_URL)
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

      def chat(conversation, tools: [], &block)
        uri = URI("#{@base_url}/api/chat")

        body = {
          model: @model_name,
          messages: format_messages(conversation.to_api_messages),
          keep_alive: ENV.fetch("OLLAMA_KEEP_ALIVE", "10m"),
          stream: true
        }

        headers = { "Content-Type" => "application/json" }

        body[:tools] = format_tools(tools) unless tools.empty?

        debug_log("Ollama request", body)

        result = post_stream(uri, headers: headers, body: body, &block)
        debug_log("Ollama response", result)
        result
      end

      private

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

            data = JSON.parse(line)
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
    end
  end
end
