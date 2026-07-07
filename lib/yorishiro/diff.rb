# frozen_string_literal: true

module Yorishiro
  # Minimal unified-diff generator used to preview file changes in the
  # permission prompt. A single hunk is built by stripping the common
  # prefix/suffix lines — accurate for the local edits tools make, and
  # O(n) without an external diff gem.
  module Diff
    CONTEXT_LINES = 3
    MAX_DIFF_LINES = 200

    module_function

    # Returns a unified diff between the two texts, or nil when they are
    # identical. When old_text is empty the file is treated as new
    # (--- /dev/null, every line added).
    def unified(old_text, new_text, path:)
      return nil if old_text == new_text

      old_lines = old_text.lines(chomp: true)
      new_lines = new_text.lines(chomp: true)

      prefix = common_prefix_length(old_lines, new_lines)
      suffix = common_suffix_length(old_lines, new_lines, prefix)

      removed = old_lines[prefix...(old_lines.length - suffix)] || []
      added = new_lines[prefix...(new_lines.length - suffix)] || []

      header(old_text, path) + hunk(old_lines, prefix, suffix, removed, added)
    end

    # Adds ANSI colors to a diff produced by .unified. Kept separate so
    # callers can decide whether the output supports color.
    def colorize(diff_text)
      diff_text.lines(chomp: true).map { |line| colorize_line(line) }.join("\n")
    end

    def common_prefix_length(old_lines, new_lines)
      max = [old_lines.length, new_lines.length].min
      (0...max).each { |i| return i if old_lines[i] != new_lines[i] }
      max
    end

    def common_suffix_length(old_lines, new_lines, prefix)
      max = [old_lines.length, new_lines.length].min - prefix
      (0...max).each { |i| return i if old_lines[-1 - i] != new_lines[-1 - i] }
      max
    end

    def header(old_text, path)
      # "/dev/null" is the unified-diff convention for a new file, not a
      # filesystem path, so File::NULL would be wrong on Windows.
      original = old_text.empty? ? "/dev/null" : path # rubocop:disable Style/FileNull
      "--- #{original}\n+++ #{path}\n"
    end

    def hunk(old_lines, prefix, suffix, removed, added)
      context_start = [prefix - CONTEXT_LINES, 0].max
      before = old_lines[context_start...prefix] || []
      after = old_lines[old_lines.length - suffix, CONTEXT_LINES] || []

      old_count = before.length + removed.length + after.length
      new_count = before.length + added.length + after.length
      old_start = old_count.zero? ? 0 : context_start + 1
      new_start = new_count.zero? ? 0 : context_start + 1

      lines = ["@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@"]
      lines += before.map { |l| " #{l}" }
      lines += removed.map { |l| "-#{l}" }
      lines += added.map { |l| "+#{l}" }
      lines += after.map { |l| " #{l}" }
      truncate(lines).join("\n")
    end

    def truncate(lines)
      return lines if lines.length <= MAX_DIFF_LINES

      lines.first(MAX_DIFF_LINES) + ["... (diff truncated, #{lines.length - MAX_DIFF_LINES} more lines)"]
    end

    def colorize_line(line)
      return line if line.start_with?("--- ", "+++ ")

      case line
      when /\A@@/ then "\e[36m#{line}\e[0m"
      when /\A\+/ then "\e[32m#{line}\e[0m"
      when /\A-/ then "\e[31m#{line}\e[0m"
      else line
      end
    end
  end
end
