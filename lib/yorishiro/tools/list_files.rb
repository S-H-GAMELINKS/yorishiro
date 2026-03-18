# frozen_string_literal: true

module Yorishiro
  module Tools
    class ListFiles < Tool
      def read_only?
        true
      end

      def name
        "list_files"
      end

      def description
        "List files in a directory. Optionally filter with a glob pattern."
      end

      def parameters
        {
          type: "object",
          properties: {
            path: { type: "string", description: "The directory path to list (default: current directory)" },
            pattern: { type: "string", description: "Glob pattern to filter files (e.g., '**/*.rb')" }
          },
          required: []
        }
      end

      def execute(**params)
        path = params[:path] || params["path"] || "."
        pattern = params[:pattern] || params["pattern"]

        raise "Directory not found: #{path}" unless Dir.exist?(path)

        if pattern
          glob_path = File.join(path, pattern)
          files = Dir.glob(glob_path)
        else
          files = Dir.children(path).sort
        end

        files.map { |f| File.directory?(f) ? "#{f}/" : f }.join("\n")
      end
    end
  end
end
