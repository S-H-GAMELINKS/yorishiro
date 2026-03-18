# frozen_string_literal: true

require "open3"

module Yorishiro
  module Tools
    class ExecuteCommand < Tool
      def initialize
        super
        @allow_commands = []
        @session_allowed = Set.new
      end

      def name
        "execute_command"
      end

      def description
        "Execute a shell command and return its output. Requires user permission unless the command matches an allowed pattern."
      end

      def parameters
        {
          type: "object",
          properties: {
            command: { type: "string", description: "The shell command to execute" }
          },
          required: ["command"]
        }
      end

      def execute(**params)
        command = params[:command] || params["command"]

        stdout, stderr, status = Open3.capture3(command)

        output = +""
        output << stdout unless stdout.empty?
        output << "\nSTDERR: #{stderr}" unless stderr.empty?
        output << "\nExit code: #{status.exitstatus}"
        output
      end

      def permission_check(arguments)
        command = arguments[:command] || arguments["command"]
        return :ask unless command

        return :allowed if command_allowed?(command)

        :ask
      end

      def session_allow!(command)
        @session_allowed << command
      end

      def configure(options)
        @allow_commands = Array(options[:allow_commands] || options["allow_commands"])
      end

      private

      def command_allowed?(command)
        return true if @session_allowed.include?(command)

        @allow_commands.any? { |pattern| File.fnmatch(pattern, command) }
      end
    end
  end
end
