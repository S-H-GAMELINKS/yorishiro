# frozen_string_literal: true

module Yorishiro
  class Conversation
    # Rough heuristic used to estimate token counts without a real tokenizer.
    # English/code averages ~4 characters per token.
    CHARS_PER_TOKEN = 4

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

    # Rough estimate of the prompt size in tokens (system prompt + all messages).
    def estimated_tokens
      total = @system_prompt.to_s.length
      total += @messages.sum { |msg| message_char_size(msg) }
      (total.to_f / CHARS_PER_TOKEN).ceil
    end

    # Replace the oldest rounds with a single summary while keeping the most
    # recent +keep_recent_rounds+ rounds verbatim. The block receives the old
    # messages and must return the summary text; rounds are handled whole so a
    # tool call is never split from its result, and the summary is inserted as a
    # leading :user message (keeping the user-first ordering providers expect).
    # Returns the number of messages that were compacted away (0 if there was
    # nothing old enough to compact or the summary came back empty).
    def compact!(keep_recent_rounds: 2)
      starts = user_message_indices
      return 0 if starts.length <= keep_recent_rounds

      cut = starts[starts.length - keep_recent_rounds]
      old = @messages[0...cut]
      return 0 if old.empty?

      summary = yield(old)
      return 0 if summary.nil? || summary.strip.empty?

      @messages = [summary_message(summary)] + (@messages[cut..] || [])
      old.length
    end

    # Drop the oldest conversation rounds until the estimated size fits within
    # +max_tokens+. A "round" starts at a :user message and includes the
    # assistant reply and any tool results that follow, so whole rounds are
    # removed together — never splitting an assistant tool_call from its tool
    # result. The system prompt and the most recent round are always kept.
    # Returns the number of messages removed.
    def trim_to_budget!(max_tokens:)
      removed_count = 0

      while estimated_tokens > max_tokens
        round_starts = user_message_indices
        break if round_starts.length <= 1 # keep at least the latest round

        removed = @messages.slice!(0, round_starts[1])
        removed_count += removed.length
      end

      removed_count
    end

    private

    def user_message_indices
      @messages.each_index.select { |i| @messages[i][:role] == :user }
    end

    def summary_message(summary)
      { role: :user, content: "[Summary of earlier conversation]\n#{summary}" }
    end

    def message_char_size(msg)
      size = msg[:content].to_s.length
      size += msg[:tool_calls].to_s.length if msg[:tool_calls]
      size
    end

    def validate_role!(role)
      return if %i[user assistant tool].include?(role)

      raise ArgumentError, "Invalid role: #{role}. Must be :user, :assistant, or :tool"
    end
  end
end
