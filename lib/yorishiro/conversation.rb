# frozen_string_literal: true

module Yorishiro
  class Conversation
    attr_reader :messages

    def initialize(system_prompt: nil)
      @messages = []
      @system_prompt = system_prompt
    end

    def add_message(role, content, tool_calls: nil, tool_call_id: nil)
      validate_role!(role)
      @messages << {
        role: role,
        content: content,
        tool_calls: tool_calls,
        tool_call_id: tool_call_id
      }.compact
    end

    def add_tool_result(tool_call_id:, content:)
      @messages << {
        role: :tool,
        content: content,
        tool_call_id: tool_call_id
      }
    end

    def to_api_messages
      msgs = @messages.map do |msg|
        converted = { role: msg[:role].to_s, content: msg[:content] }
        converted[:tool_calls] = msg[:tool_calls] if msg[:tool_calls]
        converted[:tool_call_id] = msg[:tool_call_id] if msg[:tool_call_id]
        converted
      end

      msgs.unshift({ role: "system", content: @system_prompt }) if @system_prompt

      msgs
    end

    def clear
      @messages.clear
    end

    def last_role
      @messages.last&.fetch(:role, nil)
    end

    def length
      @messages.length
    end

    private

    def validate_role!(role)
      return if %i[user assistant tool].include?(role)

      raise ArgumentError, "Invalid role: #{role}. Must be :user, :assistant, or :tool"
    end
  end
end
