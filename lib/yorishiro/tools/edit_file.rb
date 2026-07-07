# frozen_string_literal: true

module Yorishiro
  module Tools
    class EditFile < Tool
      def name
        "edit_file"
      end

      def description
        "Replace an exact string in a file. old_string must match the file content exactly " \
          "(including whitespace and indentation) and must be unique unless replace_all is true."
      end

      def parameters
        {
          type: "object",
          properties: {
            path: { type: "string", description: "The file path to edit" },
            old_string: { type: "string", description: "The exact text to replace" },
            new_string: { type: "string", description: "The text to replace it with" },
            replace_all: { type: "boolean", description: "Replace all occurrences (default: false)" }
          },
          required: %w[path old_string new_string]
        }
      end

      def execute(**params)
        path = params[:path] || params["path"]
        old_string = params[:old_string] || params["old_string"]
        new_string = params[:new_string] || params["new_string"]
        replace_all = params[:replace_all] || params["replace_all"] || false

        raise "File not found: #{path}" unless File.exist?(path)
        raise "Not a file: #{path}" unless File.file?(path)

        content = File.read(path)
        new_content, count = apply_edit(content, old_string, new_string, replace_all, path)

        File.write(path, new_content)
        "Successfully replaced #{count} occurrence(s) in #{path}"
      end

      def permission_check(_arguments)
        :ask
      end

      def preview(arguments)
        path = arguments[:path] || arguments["path"]
        old_string = arguments[:old_string] || arguments["old_string"]
        new_string = arguments[:new_string] || arguments["new_string"]
        replace_all = arguments[:replace_all] || arguments["replace_all"] || false
        return nil unless path && old_string && new_string
        return nil unless File.file?(path)

        content = File.read(path)
        new_content, = apply_edit(content, old_string, new_string, replace_all, path)
        Diff.unified(content, new_content, path: path)
      rescue StandardError
        nil
      end

      private

      def apply_edit(content, old_string, new_string, replace_all, path)
        raise "old_string and new_string are identical. Provide a different new_string." if old_string == new_string

        count = content.scan(old_string).length
        if count.zero?
          raise "old_string not found in #{path}. Read the file first and copy the exact text, " \
                "including whitespace and indentation."
        end
        if count > 1 && !replace_all
          raise "old_string appears #{count} times in #{path}. Add surrounding lines to make it unique, " \
                "or set replace_all: true."
        end

        # Block form so backreference sequences (\1, \\) in new_string are
        # written literally instead of being interpreted.
        new_content = replace_all ? content.gsub(old_string) { new_string } : content.sub(old_string) { new_string }
        [new_content, replace_all ? count : 1]
      rescue ArgumentError => e
        raise "Cannot edit #{path}: #{e.message}"
      end
    end
  end
end
