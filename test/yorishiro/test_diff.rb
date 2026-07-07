# frozen_string_literal: true

require "test_helper"

class TestDiff < Minitest::Test
  def test_unified_returns_nil_when_unchanged
    assert_nil Yorishiro::Diff.unified("same\n", "same\n", path: "a.txt")
  end

  def test_unified_single_line_change
    old_text = "line 1\nline 2\nline 3\nline 4\nline 5\n"
    new_text = "line 1\nline 2\nCHANGED\nline 4\nline 5\n"

    diff = Yorishiro::Diff.unified(old_text, new_text, path: "a.txt")

    assert_includes diff, "--- a.txt"
    assert_includes diff, "+++ a.txt"
    assert_includes diff, "-line 3"
    assert_includes diff, "+CHANGED"
    assert_includes diff, " line 2"
    assert_includes diff, " line 4"
    assert_includes diff, "@@ -1,5 +1,5 @@"
  end

  def test_unified_new_file_all_additions
    diff = Yorishiro::Diff.unified("", "line 1\nline 2\n", path: "new.txt")

    assert_includes diff, "--- /dev/null"
    assert_includes diff, "+++ new.txt"
    assert_includes diff, "+line 1"
    assert_includes diff, "+line 2"
    refute_match(/^-[^-]/, diff)
    assert_includes diff, "@@ -0,0 +1,2 @@"
  end

  def test_unified_deletion_only
    old_text = "keep\nremove me\nkeep too\n"
    new_text = "keep\nkeep too\n"

    diff = Yorishiro::Diff.unified(old_text, new_text, path: "a.txt")

    assert_includes diff, "-remove me"
    refute_match(/^\+[^+]/, diff)
  end

  def test_unified_limits_context_lines
    old_lines = (1..20).map { |i| "line #{i}" }
    new_lines = old_lines.dup
    new_lines[9] = "CHANGED"

    diff = Yorishiro::Diff.unified("#{old_lines.join("\n")}\n", "#{new_lines.join("\n")}\n", path: "a.txt")

    assert_includes diff, " line 7"
    assert_includes diff, " line 13"
    refute_includes diff, "line 6"
    refute_includes diff, "line 14"
    assert_includes diff, "@@ -7,7 +7,7 @@"
  end

  def test_unified_change_at_start_of_file
    diff = Yorishiro::Diff.unified("first\nrest\n", "FIRST\nrest\n", path: "a.txt")

    assert_includes diff, "-first"
    assert_includes diff, "+FIRST"
    assert_includes diff, "@@ -1,2 +1,2 @@"
  end

  def test_unified_truncates_huge_diffs
    old_text = ""
    new_text = "#{Array.new(300) { |i| "line #{i}" }.join("\n")}\n"

    diff = Yorishiro::Diff.unified(old_text, new_text, path: "a.txt")

    assert_operator diff.lines.length, :<=, Yorishiro::Diff::MAX_DIFF_LINES + 3 # + headers + notice
    assert_includes diff, "diff truncated"
  end

  def test_colorize_adds_ansi_colors
    diff = "--- a.txt\n+++ a.txt\n@@ -1,1 +1,1 @@\n-old\n+new"

    colored = Yorishiro::Diff.colorize(diff)

    assert_includes colored, "\e[31m-old\e[0m"
    assert_includes colored, "\e[32m+new\e[0m"
    assert_includes colored, "\e[36m@@ -1,1 +1,1 @@\e[0m"
    assert_includes colored, "--- a.txt\n"
    refute_includes colored, "\e[31m--- a.txt"
    refute_includes colored, "\e[32m+++ a.txt"
  end
end
