# frozen_string_literal: true

module Yorishiro
  module Tools
    class Grep < Tool
      MAX_RESULTS = 100
      EXCLUDED_DIRS = %w[.git node_modules vendor tmp].freeze
      BINARY_CHECK_BYTES = 8_000
      MAX_LINE_LENGTH = 250

      def read_only?
        true
      end

      def name
        "grep"
      end

      def description
        "Search file contents recursively with a Ruby regular expression. " \
          "Returns matches as 'file:line:content'. Hidden files and directories (e.g. .git) are skipped."
      end

      def parameters
        {
          type: "object",
          properties: {
            pattern: { type: "string", description: "Ruby regular expression to search for" },
            path: { type: "string", description: "Directory to search in (default: current directory)" },
            glob: { type: "string", description: "Glob pattern to filter files (e.g., '*.rb')" }
          },
          required: ["pattern"]
        }
      end

      def execute(**params)
        pattern = params[:pattern] || params["pattern"]
        path = params[:path] || params["path"] || "."
        glob = params[:glob] || params["glob"]

        regexp = build_regexp(pattern)
        raise "Directory not found: #{path}" unless Dir.exist?(path)

        matches, truncated = search(regexp, path, glob)
        format_results(matches, truncated, pattern)
      end

      private

      def build_regexp(pattern)
        Regexp.new(pattern)
      rescue RegexpError => e
        raise "Invalid regular expression: #{e.message}"
      end

      def search(regexp, path, glob)
        matches = []

        target_files(path, glob).each do |file|
          scan_file(file, regexp) do |line_number, line|
            return [matches, true] if matches.length >= MAX_RESULTS

            matches << "#{file}:#{line_number}:#{line}"
          end
        end

        [matches, false]
      end

      # Dir.glob without FNM_DOTMATCH already skips dotfiles and dot
      # directories; EXCLUDED_DIRS guards against globs that reach into
      # them explicitly (e.g. vendored or dependency directories).
      def target_files(path, glob)
        glob_pattern = File.join(path, glob ? "**/#{glob}" : "**/*")
        Dir.glob(glob_pattern).select do |file|
          File.file?(file) && !excluded?(file, path)
        end
      end

      # Only path components below the search root count as excluded, so
      # searching inside e.g. /tmp/project still works.
      def excluded?(file, base)
        relative = file.delete_prefix(File.join(base, ""))
        relative.split(File::SEPARATOR).any? { |part| EXCLUDED_DIRS.include?(part) }
      end

      def scan_file(file, regexp)
        return if binary?(file)

        File.foreach(file).with_index(1) do |line, line_number|
          line = line.scrub.chomp
          yield line_number, truncate_line(line) if regexp.match?(line)
        end
      rescue SystemCallError
        # Unreadable files are skipped.
      end

      def binary?(file)
        chunk = File.binread(file, BINARY_CHECK_BYTES)
        chunk&.include?("\0")
      rescue SystemCallError
        true
      end

      def truncate_line(line)
        line.length > MAX_LINE_LENGTH ? "#{line[0...MAX_LINE_LENGTH]}..." : line
      end

      def format_results(matches, truncated, pattern)
        return "No matches found for pattern: #{pattern}" if matches.empty?

        result = matches.join("\n")
        result += "\n... (truncated: showing first #{MAX_RESULTS} matches)" if truncated
        result
      end
    end
  end
end
