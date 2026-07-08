# frozen_string_literal: true

module Yorishiro
  module Tools
    class ReadFile < Tool
      # Cap how much of a file one call can return. Small local-model
      # context windows (e.g. Ollama with num_ctx 8192) are exhausted by a
      # single whole-file dump, so large files must be paged instead.
      MAX_LINES = 200
      MAX_LINE_LENGTH = 500

      def read_only?
        true
      end

      def name
        "read_file"
      end

      def description
        "Read the contents of a file at the specified path. Returns at most #{MAX_LINES} lines per call; " \
          "use offset and limit to page through larger files."
      end

      def parameters
        {
          type: "object",
          properties: {
            path: { type: "string", description: "The file path to read" },
            offset: { type: "integer", description: "Line number to start reading from (0-based)" },
            limit: { type: "integer", description: "Maximum number of lines to read (capped at #{MAX_LINES})" }
          },
          required: ["path"]
        }
      end

      def execute(**params)
        path = params[:path] || params["path"]
        offset = (params[:offset] || params["offset"]).to_i
        limit = (params[:limit] || params["limit"])&.to_i
        limit = limit.nil? ? MAX_LINES : [limit, MAX_LINES].min

        raise "File not found: #{path}" unless File.exist?(path)
        raise "Not a file: #{path}" unless File.file?(path)

        lines = File.readlines(path)
        selected = lines[offset, limit] || []

        output = selected.each_with_index.map { |line, i| "#{offset + i + 1}: #{truncate_line(line)}" }.join
        output + paging_notice(lines.length, offset, selected.length)
      end

      private

      def truncate_line(line)
        return line if line.chomp.length <= MAX_LINE_LENGTH

        "#{line.chomp[0...MAX_LINE_LENGTH]}... (line truncated)\n"
      end

      def paging_notice(total, offset, shown)
        return "" unless total > offset + shown

        "... (file has #{total} lines; showing #{offset + 1}-#{offset + shown}. Use offset/limit to read more.)"
      end
    end
  end
end
