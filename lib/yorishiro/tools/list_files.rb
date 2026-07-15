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

        entries = if pattern
                    # Glob results already carry the path prefix.
                    Dir.glob(File.join(path, pattern)).map { |f| [f, f] }
                  else
                    # Dir.children returns bare names — resolve them against
                    # +path+, not the process cwd, when checking for directories.
                    Dir.children(path).sort.map { |name| [name, File.join(path, name)] }
                  end

        entries.map { |display, full| File.directory?(full) ? "#{display}/" : display }.join("\n")
      end
    end
  end
end
