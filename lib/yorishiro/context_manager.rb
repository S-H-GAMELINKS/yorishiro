# frozen_string_literal: true

module Yorishiro
  class ContextManager
    attr_reader :root_path, :ignored_patterns

    def initialize(root_path = Dir.pwd)
      @root_path = File.expand_path(root_path)
      # Patterns to exclude from the map to save tokens and reduce noise
      @ignored_patterns = [/^\.git/, /node_modules/, /vendor/, %r{\.git/.*}, /spec/, /test/]
    end

    # Generates a tree-like map of the project structure for LLM consumption.
    # max_depth limits how deep the recursion goes to keep context concise.
    def generate_map(max_depth: 3)
      tree = []
      scan_directory(@root_path, max_depth, tree)
      tree.join("\n")
    end

    private

    def scan_directory(path, depth, tree)
      return if depth <= 0

      begin
        entries = Dir.children(path).sort
        entries.each do |entry|
          full_path = File.expand_path(File.join(path, entry))

          next if ignored?(full_path)

          if File.directory?(full_path)
            tree << "[Dir] #{entry}"
            scan_directory(full_path, depth - 1, tree)
          else
            # Add indentation based on current depth
            indent = "  " * (3 - depth)
            tree << "#{indent}#{entry}"
          end
        end
      rescue Errno::EACCES
        # Skip directories with no permissions
      end
    end

    def ignored?(path)
      @ignored_patterns.any? { |pattern| path =~ pattern }
    end
  end
end
