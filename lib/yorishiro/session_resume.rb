# frozen_string_literal: true

require "reline"

module Yorishiro
  # Interactive session-resume flows shared by the --continue/--resume CLI
  # flags and the /resume command. Applies the chosen session to the
  # conversation and returns its id, or nil when nothing was resumed (the
  # caller keeps its current session in that case).
  class SessionResume
    def initialize(store:, conversation:, output:, current_target:)
      @store = store
      @conversation = conversation
      @output = output
      @current_target = current_target # "provider:model" of the running CLI
    end

    def continue_latest
      apply(@store.latest, missing: "No previous session found. Starting a new one.")
    end

    def resume_by_id(id)
      apply(@store.load(id), missing: "Session not found: #{id}")
    end

    def pick
      sessions = @store.list
      if sessions.empty?
        @output.puts "[i] No saved sessions."
        return nil
      end

      print_list(sessions)
      answer = Reline.readline("Select session [1-#{sessions.length}]: ", false)&.strip
      index = answer.to_i
      unless index.between?(1, sessions.length)
        @output.puts "Cancelled."
        return nil
      end

      apply(sessions[index - 1])
    end

    private

    def apply(session, missing: "Session not found.")
      unless session
        @output.puts "[i] #{missing}"
        return nil
      end

      unless @store.claim(session[:id])
        @output.puts "[i] Session #{session[:id]} is in use by another process. Starting a new session."
        return nil
      end

      @conversation.restore_messages!(session[:messages])

      recorded = "#{session[:provider]}:#{session[:model]}"
      @output.puts "[i] This session was recorded with #{recorded}. Continuing with #{@current_target}." if recorded != @current_target
      @output.puts "[i] Resumed session #{session[:id]} (#{session[:title]}, #{session[:messages].length} messages)"
      session[:id]
    end

    def print_list(sessions)
      sessions.each_with_index do |session, index|
        stamp = session[:updated_at].to_s[0, 16].tr("T", " ")
        @output.puts "#{(index + 1).to_s.rjust(3)}. [#{stamp}] #{session[:provider]}:#{session[:model]} " \
                     "(#{session[:messages].length} msgs) #{session[:title]}"
      end
    end
  end
end
