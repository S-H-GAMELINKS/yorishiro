# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestSessionStore < Minitest::Test
  def test_save_creates_session_file_with_schema
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)

      id = store.save(id: nil, messages: messages, provider: :ollama, model: "gemma4:12b")

      refute_nil id
      data = JSON.parse(File.read(File.join(dir, ".yorishiro", "sessions", "#{id}.json")))
      assert_equal 1, data["version"]
      assert_equal id, data["id"]
      assert_equal "ollama", data["provider"]
      assert_equal "gemma4:12b", data["model"]
      refute_nil data["created_at"]
      refute_nil data["updated_at"]
      assert_equal "hello there", data["title"]
    end
  end

  def test_save_reuses_id_and_preserves_created_at
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)

      id = store.save(id: nil, messages: messages, provider: :ollama, model: "m")
      created_at = store.load(id)[:created_at]
      same_id = store.save(id: id, messages: messages, provider: :ollama, model: "m")

      assert_equal id, same_id
      assert_equal created_at, store.load(id)[:created_at]
      assert_equal 1, Dir.glob(File.join(dir, ".yorishiro", "sessions", "*.json")).length
    end
  end

  def test_save_truncates_long_title_to_first_line
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      long = "#{"x" * 100}\nsecond line"

      id = store.save(id: nil, messages: [{ "role" => "user", "content" => long }], provider: :ollama, model: "m")

      title = store.load(id)[:title]
      assert title.start_with?("x" * 60)
      assert title.end_with?("...")
      refute_includes title, "second line"
    end
  end

  def test_load_round_trips_tool_call_messages
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      tool_calls = [{ "id" => "t1", "name" => "read_file", "arguments" => { "path" => "a.txt" } }]
      msgs = [
        { "role" => "user", "content" => "read a file" },
        { "role" => "assistant", "content" => "", "tool_calls" => tool_calls },
        { "role" => "tool", "content" => "contents", "tool_call_id" => "t1" }
      ]

      id = store.save(id: nil, messages: msgs, provider: :ollama, model: "m")

      assert_equal msgs, store.load(id)[:messages]
    end
  end

  def test_load_by_id_prefix
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      id = store.save(id: nil, messages: messages, provider: :ollama, model: "m")

      assert_equal id, store.load(id[0, 8])[:id]
    end
  end

  def test_load_returns_nil_for_unknown_id
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)

      assert_nil store.load("nope")
    end
  end

  def test_load_and_list_ignore_corrupt_files
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      id = store.save(id: nil, messages: messages, provider: :ollama, model: "m")
      File.write(File.join(dir, ".yorishiro", "sessions", "zz-corrupt.json"), "{not json")

      assert_nil store.load("zz-corrupt")
      assert_equal([id], store.list.map { |s| s[:id] })
    end
  end

  def test_latest_and_list_order_by_updated_at
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      older = store.save(id: "20260101T000000-aaaaaa", messages: messages, provider: :ollama, model: "m")
      newer = store.save(id: "20260102T000000-bbbbbb", messages: messages, provider: :ollama, model: "m")
      bump_updated_at(dir, older, "2099-01-01T00:00:00Z")

      assert_equal([older, newer], store.list.map { |s| s[:id] })
      assert_equal older, store.latest[:id]
    end
  end

  def test_prune_deletes_oldest_beyond_max
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir, max_sessions: 2)
      first = store.save(id: nil, messages: messages, provider: :ollama, model: "m")
      second = store.save(id: nil, messages: messages, provider: :ollama, model: "m")
      third = store.save(id: nil, messages: messages, provider: :ollama, model: "m")

      remaining = Dir.glob(File.join(dir, ".yorishiro", "sessions", "*.json")).map { |p| File.basename(p, ".json") }
      assert_equal 2, remaining.length
      refute_includes remaining, first
      assert_includes remaining, second
      assert_includes remaining, third
    end
  end

  def test_save_leaves_no_tmp_file
    Dir.mktmpdir do |dir|
      store = Yorishiro::SessionStore.new(dir: dir)
      store.save(id: nil, messages: messages, provider: :ollama, model: "m")

      assert_empty Dir.glob(File.join(dir, ".yorishiro", "sessions", "*.tmp"))
    end
  end

  def test_save_returns_nil_when_directory_is_not_writable
    store = Yorishiro::SessionStore.new(dir: "/nonexistent-root/deep")

    FileUtils.stub(:mkdir_p, ->(_dir) { raise Errno::EACCES }) do
      assert_nil store.save(id: nil, messages: messages, provider: :ollama, model: "m")
    end
  end

  private

  def messages
    [
      { "role" => "user", "content" => "hello there" },
      { "role" => "assistant", "content" => "hi!" }
    ]
  end

  def bump_updated_at(dir, id, timestamp)
    path = File.join(dir, ".yorishiro", "sessions", "#{id}.json")
    data = JSON.parse(File.read(path))
    data["updated_at"] = timestamp
    File.write(path, JSON.generate(data))
  end
end
