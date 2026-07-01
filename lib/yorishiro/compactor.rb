# frozen_string_literal: true

module Yorishiro
  # Summarizes older conversation history into a compact summary so long
  # sessions stay within the model's context window (similar to Claude Code's
  # auto-compaction). Uses the active provider to generate the summary.
  class Compactor
    KEEP_RECENT_ROUNDS = 2

    SUMMARY_SYSTEM_PROMPT = <<~PROMPT
      You compress conversation history for an AI coding assistant. Produce a
      concise but complete summary that preserves everything needed to continue
      the work: the user's goals and requests, key decisions made, files and
      code examined or changed, tool results that still matter, and any
      unresolved questions or next steps. Prefer terse bullet points. Do not add
      commentary or ask questions — output only the summary.
    PROMPT

    SUMMARY_INSTRUCTION = "Summarize the following conversation transcript so the assistant can continue seamlessly:"

    def initialize(provider)
      @provider = provider
    end

    # Compact the given conversation in place. Returns the number of messages
    # that were summarized away (0 if nothing was compacted).
    def compact(conversation, keep_recent_rounds: KEEP_RECENT_ROUNDS)
      conversation.compact!(keep_recent_rounds: keep_recent_rounds) do |old_messages|
        summarize(old_messages)
      end
    end

    private

    def summarize(old_messages)
      transcript = old_messages.map { |msg| format_message(msg) }.join("\n\n")

      request = Conversation.new(system_prompt: SUMMARY_SYSTEM_PROMPT)
      request.add_message(:user, "#{SUMMARY_INSTRUCTION}\n\n#{transcript}")

      @provider.chat(request)[:content]
    end

    def format_message(msg)
      lines = ["#{msg[:role]}: #{msg[:content]}"]
      if msg[:tool_calls]
        calls = msg[:tool_calls].map { |tc| "#{tc[:name]}(#{tc[:arguments]})" }.join(", ")
        lines << "  [tool_calls: #{calls}]"
      end
      lines.join("\n")
    end
  end
end
