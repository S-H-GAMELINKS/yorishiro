# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "reline"

class TestInputHistory < Minitest::Test
  def setup
    Reline::HISTORY.clear
  end

  def teardown
    Reline::HISTORY.clear
  end

  def test_load_is_noop_without_file
    Dir.mktmpdir do |dir|
      history = Yorishiro::InputHistory.new(dir: dir)
      history.load # should not raise
      assert_empty Reline::HISTORY.to_a
    end
  end

  def test_save_writes_json_array_under_yorishiro_dir
    Dir.mktmpdir do |dir|
      Reline::HISTORY << "first"
      Reline::HISTORY << "second"

      history = Yorishiro::InputHistory.new(dir: dir)
      history.save

      path = File.join(dir, ".yorishiro", "history.json")
      assert File.exist?(path)
      assert_equal %w[first second], JSON.parse(File.read(path))
    end
  end

  def test_save_then_load_round_trips_into_reline_history
    Dir.mktmpdir do |dir|
      Reline::HISTORY << "hello"
      Yorishiro::InputHistory.new(dir: dir).save

      Reline::HISTORY.clear
      Yorishiro::InputHistory.new(dir: dir).load

      assert_equal ["hello"], Reline::HISTORY.to_a
    end
  end

  def test_round_trips_multi_line_entry
    Dir.mktmpdir do |dir|
      entry = "line one\nline two\nline three"
      Reline::HISTORY << entry
      Yorishiro::InputHistory.new(dir: dir).save

      Reline::HISTORY.clear
      Yorishiro::InputHistory.new(dir: dir).load

      assert_equal [entry], Reline::HISTORY.to_a
    end
  end

  def test_save_trims_to_max_entries
    Dir.mktmpdir do |dir|
      5.times { |i| Reline::HISTORY << "entry#{i}" }
      Yorishiro::InputHistory.new(dir: dir, max_entries: 2).save

      path = File.join(dir, ".yorishiro", "history.json")
      assert_equal %w[entry3 entry4], JSON.parse(File.read(path))
    end
  end

  def test_load_ignores_corrupt_file
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".yorishiro"))
      File.write(File.join(dir, ".yorishiro", "history.json"), "{ not json")

      Yorishiro::InputHistory.new(dir: dir).load # should not raise
      assert_empty Reline::HISTORY.to_a
    end
  end

  def test_default_path_is_under_cwd
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        history = Yorishiro::InputHistory.new
        assert_equal File.join(Dir.pwd, ".yorishiro", "history.json"), history.path
      end
    end
  end
end
