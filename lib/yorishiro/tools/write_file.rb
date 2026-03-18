# frozen_string_literal: true

module Yorishiro
  module Tools
    class WriteFile < Tool
      def name
        "write_file"
      end

      def description
        "Write content to a file at the specified path. Creates the file if it doesn't exist, overwrites if it does."
      end

      def parameters
        {
          type: "object",
          properties: {
            path: { type: "string", description: "The file path to write to" },
            content: { type: "string", description: "The content to write to the file" }
          },
          required: %w[path content]
        }
      end

      def execute(**params)
        path = params[:path] || params["path"]
        content = params[:content] || params["content"]

        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)

        File.write(path, content)
        "Successfully wrote #{content.bytesize} bytes to #{path}"
      end

      def permission_check(_arguments)
        :ask
      end
    end
  end
end
