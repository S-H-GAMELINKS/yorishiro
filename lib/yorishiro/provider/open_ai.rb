# frozen_string_literal: true

module Yorishiro
  module Provider
    class OpenAI < Base
      API_URL = "https://api.openai.com/v1/chat/completions"

      # Chat-completions models compatible with this client, which always
      # streams and sends system messages and tools — the o1/o3 reasoning
      # series rejects parts of that flow, so it is intentionally absent.
      SUPPORTED_MODELS = %w[
        gpt-4o
        gpt-4o-mini
        gpt-4-turbo
        gpt-4
        gpt-3.5-turbo
      ].freeze

      def self.supported_models
        SUPPORTED_MODELS
      end

      def chat(conversation, tools: [], &)
        uri = URI(API_URL)

        body = {
          model: @model_name,
          messages: format_messages(conversation.to_api_messages),
          stream: true,
          stream_options: { include_usage: true }
        }
        body[:tools] = format_tools(tools) unless tools.empty?

        headers = {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{@api_key}"
        }

        @last_usage = {}
        result = post_stream(uri, headers: headers, body: body, &)
        result[:usage] = @last_usage
        result
      end

      private

      def default_model
        "gpt-4o"
      end

      def format_messages(api_messages)
        api_messages.map do |msg|
          if msg[:role] == "tool"
            {
              role: "tool",
              tool_call_id: msg[:tool_call_id],
              content: msg[:content]
            }
          elsif msg[:tool_calls]&.any?
            formatted = { role: "assistant" }
            formatted[:content] = msg[:content] if msg[:content] && !msg[:content].empty?
            formatted[:tool_calls] = msg[:tool_calls].map do |tc|
              {
                id: tc[:id],
                type: "function",
                function: {
                  name: tc[:name],
                  arguments: JSON.generate(tc[:arguments])
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

      # A trailing usage-only chunk (with an empty choices array) carries the
      # token counts when stream_options.include_usage is set.
      def capture_usage(data)
        usage = data["usage"]
        return unless usage

        @last_usage[:input] = usage["prompt_tokens"]
        @last_usage[:output] = usage["completion_tokens"]
      end

      def parse_stream(response, tool_calls:, &block)
        buffer = +""
        tool_call_buffers = {}

        response.read_body do |chunk|
          buffer << chunk
          while (idx = buffer.index("\n\n"))
            event_str = buffer.slice!(0, idx + 2)
            parsed = parse_sse_event(event_str)
            next unless parsed[:data]

            capture_usage(parsed[:data])

            choice = parsed[:data].dig("choices", 0)
            next unless choice

            delta = choice["delta"]
            next unless delta

            block&.call(delta["content"]) if delta["content"]

            delta["tool_calls"]&.each do |tc_delta|
              index = tc_delta["index"]
              tool_call_buffers[index] ||= { id: nil, name: nil, arguments_json: +"" }

              buf = tool_call_buffers[index]
              buf[:id] = tc_delta["id"] if tc_delta["id"]
              buf[:name] = tc_delta.dig("function", "name") if tc_delta.dig("function", "name")
              buf[:arguments_json] << tc_delta.dig("function", "arguments").to_s
            end

            next unless choice["finish_reason"]

            tool_call_buffers.each_value do |buf|
              next unless buf[:id] && buf[:name]

              arguments = buf[:arguments_json].empty? ? {} : JSON.parse(buf[:arguments_json])
              tool_calls << {
                id: buf[:id],
                name: buf[:name],
                arguments: arguments
              }
            end
            tool_call_buffers.clear
          end
        end
      end
    end
  end
end
