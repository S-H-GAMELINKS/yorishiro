# frozen_string_literal: true

module Yorishiro
  module Provider
    class Anthropic < Base
      API_URL = "https://api.anthropic.com/v1/messages"
      API_VERSION = "2023-06-01"

      SUPPORTED_MODELS = %w[
        claude-opus-4-20250514
        claude-sonnet-4-20250514
        claude-haiku-4-20250414
        claude-3-5-sonnet-20241022
        claude-3-5-haiku-20241022
      ].freeze

      def self.supported_models
        SUPPORTED_MODELS
      end

      def chat(conversation, tools: [], &)
        uri = URI(API_URL)
        messages = format_messages(conversation.to_api_messages)
        system_prompt = extract_system_prompt(conversation.to_api_messages)

        body = {
          model: @model_name,
          max_tokens: 8192,
          messages: messages,
          stream: true
        }
        body[:system] = system_prompt if system_prompt
        body[:tools] = format_tools(tools) unless tools.empty?

        headers = {
          "Content-Type" => "application/json",
          "x-api-key" => @api_key,
          "anthropic-version" => API_VERSION
        }

        @last_usage = {}
        result = post_stream(uri, headers: headers, body: body, &)
        result[:usage] = @last_usage
        result
      end

      private

      def default_model
        "claude-sonnet-4-20250514"
      end

      def format_messages(api_messages)
        messages = api_messages.reject { |m| m[:role] == "system" || empty_assistant?(m) }

        messages.map do |msg|
          if msg[:role] == "tool"
            {
              role: "user",
              content: [{
                type: "tool_result",
                tool_use_id: msg[:tool_call_id],
                content: msg[:content]
              }]
            }
          elsif msg[:tool_calls]&.any?
            content = []
            content << { type: "text", text: msg[:content] } if msg[:content] && !msg[:content].empty?
            msg[:tool_calls].each do |tc|
              content << {
                type: "tool_use",
                id: tc[:id],
                name: tc[:name],
                input: tc[:arguments]
              }
            end
            { role: "assistant", content: content }
          else
            { role: msg[:role], content: msg[:content] }
          end
        end
      end

      # The API rejects assistant messages whose content is empty, and the
      # error repeats on every request — so an empty completion recorded in
      # the history (e.g. by a session saved before the CLI filtered them
      # out) is dropped rather than poisoning the whole session.
      def empty_assistant?(msg)
        msg[:role] == "assistant" && msg[:tool_calls].to_a.empty? && msg[:content].to_s.strip.empty?
      end

      def extract_system_prompt(api_messages)
        system_msg = api_messages.find { |m| m[:role] == "system" }
        system_msg&.fetch(:content, nil)
      end

      def format_tools(tools)
        tools.map do |t|
          {
            name: t[:name],
            description: t[:description],
            input_schema: t[:input_schema]
          }
        end
      end

      # input_tokens arrives on message_start, output_tokens on message_delta.
      def capture_usage(data)
        input = data.dig("message", "usage", "input_tokens")
        output = data.dig("usage", "output_tokens")
        @last_usage[:input] = input if input
        @last_usage[:output] = output if output
      end

      def parse_stream(response, tool_calls:, &block)
        buffer = +""
        current_tool_call = nil

        response.read_body do |chunk|
          buffer << chunk
          while (idx = buffer.index("\n\n"))
            event_str = buffer.slice!(0, idx + 2)
            parsed = parse_sse_event(event_str)
            next unless parsed[:data]

            case parsed[:event] || parsed[:data]["type"]
            when "message_start", "message_delta"
              capture_usage(parsed[:data])
            when "content_block_start"
              content_block = parsed[:data]["content_block"]
              if content_block && content_block["type"] == "tool_use"
                current_tool_call = {
                  id: content_block["id"],
                  name: content_block["name"],
                  arguments_json: +""
                }
              end
            when "content_block_delta"
              delta = parsed[:data]["delta"]
              if delta
                case delta["type"]
                when "text_delta"
                  block&.call(delta["text"]) if delta["text"]
                when "input_json_delta"
                  current_tool_call[:arguments_json] << delta["partial_json"] if current_tool_call
                end
              end
            when "content_block_stop"
              if current_tool_call
                arguments = current_tool_call[:arguments_json].empty? ? {} : JSON.parse(current_tool_call[:arguments_json])
                tool_calls << {
                  id: current_tool_call[:id],
                  name: current_tool_call[:name],
                  arguments: arguments
                }
                current_tool_call = nil
              end
            end
          end
        end
      end
    end
  end
end
