# frozen_string_literal: true

require "reline"

module Yorishiro
  # Persists the Reline input-line history to disk so that past prompts can be
  # recalled with the up arrow across sessions. The history file lives under the
  # launch directory (cwd), so each project keeps its own history. Entries are
  # stored as a JSON array of strings; JSON is used (rather than newline-
  # separated text) because a single multi-line input is one entry containing
  # embedded newlines.
  class InputHistory
    DIR_NAME = ".yorishiro"
    FILE_NAME = "history.json"

    # Cap the on-disk history so it does not grow without bound.
    MAX_ENTRIES = 1000

    def initialize(dir: Dir.pwd, max_entries: MAX_ENTRIES)
      @path = File.join(dir, DIR_NAME, FILE_NAME)
      @max_entries = max_entries
    end

    attr_reader :path

    # Populate Reline::HISTORY from the saved file. No-op if the file is absent
    # or unreadable/corrupt (a broken history file should never block startup).
    def load
      return unless File.exist?(@path)

      entries = JSON.parse(File.read(@path))
      return unless entries.is_a?(Array)

      entries.each { |entry| Reline::HISTORY << entry.to_s }
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # Write the current Reline::HISTORY (trimmed to the most recent
    # +max_entries+) to disk as a JSON array.
    def save
      FileUtils.mkdir_p(File.dirname(@path))
      entries = Reline::HISTORY.to_a.last(@max_entries)
      File.write(@path, JSON.generate(entries))
    rescue SystemCallError
      nil
    end
  end
end
