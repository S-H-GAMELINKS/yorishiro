# frozen_string_literal: true

require "time"

module Yorishiro
  # Persists conversations to .yorishiro/sessions/<id>.json under the
  # launch directory so they can be resumed later (--continue / --resume /
  # /resume). Each session is one JSON file rewritten wholesale through an
  # atomic tmp-file rename: compaction rewrites history destructively (an
  # append-only log would need replaying), and the atomic swap means a
  # crash mid-write never corrupts the previously saved state.
  class SessionStore
    DIR_NAME = File.join(".yorishiro", "sessions")
    MAX_SESSIONS = 50
    SCHEMA_VERSION = 1
    TITLE_MAX_LENGTH = 60

    def initialize(dir: Dir.pwd, max_sessions: MAX_SESSIONS)
      @sessions_dir = File.join(dir, DIR_NAME)
      @max_sessions = max_sessions
      @locks = {}
    end

    attr_reader :sessions_dir

    # Take exclusive ownership of a session id for this process, so a second
    # `yorishiro` resuming the same session in the same directory doesn't
    # write over this one's history (last-writer-wins data loss). Returns
    # true when acquired (or already held by us), false when another live
    # process owns it. The advisory lock is released automatically on
    # process exit. Filesystems without flock fail open to preserve the
    # single-user behaviour.
    def claim(id)
      return true if @locks.key?(id)

      FileUtils.mkdir_p(@sessions_dir)
      # Held open for the process lifetime so the advisory lock persists;
      # the block form would close it and release the lock immediately.
      lock = File.open(lock_path_for(id), File::CREAT | File::RDWR, 0o644) # rubocop:disable Style/FileOpen
      if lock.flock(File::LOCK_EX | File::LOCK_NB)
        @locks[id] = lock
        true
      else
        lock.close
        false
      end
    rescue SystemCallError
      true
    end

    # Release every lock held by this store. The OS also releases them on
    # process exit; this exists for tests and explicit teardown.
    def release_locks
      @locks.each_value { |lock| lock.close unless lock.closed? }
      @locks.clear
    end

    # Write the session and return its id (generating one when nil). The
    # original created_at is preserved across saves. Returns nil when the
    # write fails — persistence must never break a REPL turn.
    def save(id:, messages:, provider:, model:)
      id ||= generate_id
      claim(id)
      existing = parse_session(path_for(id))
      now = Time.now.utc.iso8601

      session = {
        version: SCHEMA_VERSION,
        id: id,
        provider: provider,
        model: model,
        created_at: existing&.dig(:created_at) || now,
        updated_at: now,
        title: title_from(messages),
        messages: messages
      }

      write_atomically(path_for(id), JSON.generate(session))
      prune!
      id
    rescue SystemCallError
      nil
    end

    # Load a session by exact id or id prefix (most recent match wins).
    # Returns nil when missing or corrupt.
    def load(id)
      path = path_for(id)
      path = Dir.glob(File.join(@sessions_dir, "#{id}*.json")).max unless File.exist?(path)
      return nil unless path

      parse_session(path)
    end

    def latest
      list.first
    end

    # All sessions, most recently updated first. Corrupt files are skipped.
    def list
      Dir.glob(File.join(@sessions_dir, "*.json"))
         .filter_map { |path| parse_session(path) }
         .sort_by { |session| session[:updated_at].to_s }
         .reverse
    end

    private

    def parse_session(path)
      return nil unless File.exist?(path)

      data = JSON.parse(File.read(path))
      return nil unless data.is_a?(Hash) && data["messages"].is_a?(Array)

      {
        id: data["id"],
        provider: data["provider"],
        model: data["model"],
        created_at: data["created_at"],
        updated_at: data["updated_at"],
        title: data["title"],
        messages: data["messages"]
      }
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def write_atomically(path, content)
      FileUtils.mkdir_p(@sessions_dir)
      tmp_path = "#{path}.#{Process.pid}.tmp"
      File.write(tmp_path, content)
      File.rename(tmp_path, path)
    end

    def prune!
      paths = Dir.glob(File.join(@sessions_dir, "*.json")).sort_by { |path| File.mtime(path) }
      excess = paths.length - @max_sessions
      return unless excess.positive?

      paths.first(excess).each do |path|
        File.delete(path)
        FileUtils.rm_f("#{path}.lock")
      end
    rescue SystemCallError
      nil
    end

    def path_for(id)
      File.join(@sessions_dir, "#{id}.json")
    end

    def lock_path_for(id)
      "#{path_for(id)}.lock"
    end

    # Timestamp prefix keeps ids readable and roughly sortable; the random
    # suffix avoids collisions between sessions started in the same second.
    def generate_id
      "#{Time.now.strftime("%Y%m%dT%H%M%S")}-#{SecureRandom.hex(3)}"
    end

    def title_from(messages)
      first_user = messages.find { |msg| msg["role"].to_s == "user" }
      first_line = first_user&.fetch("content", nil).to_s.lines.first.to_s.strip
      first_line.length > TITLE_MAX_LENGTH ? "#{first_line[0...TITLE_MAX_LENGTH]}..." : first_line
    end
  end
end
