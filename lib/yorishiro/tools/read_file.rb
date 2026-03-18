# frozen_string_literal: true

module Yorishiro
  module Tools
    class ReadFile < Tool
      def read_only?
        true
      end

      def name
        "read_file"
      end

      def description
        "Read the contents of a file at the specified path. Optionally specify offset and limit for partial reads."
      end

      def parameters
        {
          type: "object",
          properties: {
            path: { type: "string", description: "The file path to read" },
            offset: { type: "integer", description: "Line number to start reading from (0-based)" },
            limit: { type: "integer", description: "Maximum number of lines to read" }
          },
          required: ["path"]
        }
      end

      def execute(**params)
        path = params[:path] || params["path"]
        offset = (params[:offset] || params["offset"])&.to_i
        limit = (params[:limit] || params["limit"])&.to_i

        raise "File not found: #{path}" unless File.exist?(path)
        raise "Not a file: #{path}" unless File.file?(path)

        lines = File.readlines(path)

        if offset || limit
          offset ||= 0
          limit ||= lines.length
          lines = lines[offset, limit] || []
        end

        lines.each_with_index.map { |line, i| "#{(offset || 0) + i + 1}: #{line}" }.join
      end
    end
  end
end
