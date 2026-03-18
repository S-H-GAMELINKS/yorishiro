# frozen_string_literal: true

require "open3"
require "json"
require "securerandom"

module Yorishiro
  module MCP
    class StdioTransport
      def initialize(command:, args: [], env: {})
        @command = command
        @args = args
        @env = env
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @wait_thread = nil
        @mutex = Mutex.new
        @started = false
      end

      def start
        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@env, @command, *@args)
        @stdin.set_encoding("UTF-8")
        @stdout.set_encoding("UTF-8")
        @started = true
        send_initialize
      end

      def stop
        return unless @started

        @stdin&.close
        @stdout&.close
        @stderr&.close
        @wait_thread&.value
        @started = false
      end

      def started?
        @started
      end

      def send_request(request:)
        @mutex.synchronize do
          json = JSON.generate(request)
          @stdin.puts(json)
          @stdin.flush

          line = read_with_timeout(30)
          raise "MCP server closed connection" unless line

          JSON.parse(line)
        end
      end

      private

      def send_initialize
        response = send_request(request: {
                                  jsonrpc: "2.0",
                                  id: SecureRandom.uuid,
                                  method: "initialize",
                                  params: {
                                    protocolVersion: "2025-03-26",
                                    capabilities: {},
                                    clientInfo: { name: "yorishiro", version: Yorishiro::VERSION }
                                  }
                                })

        notification = JSON.generate({ jsonrpc: "2.0", method: "notifications/initialized" })
        @stdin.puts(notification)
        @stdin.flush

        response
      end

      def read_with_timeout(timeout_seconds)
        raise "MCP server response timeout (#{timeout_seconds}s)" unless @stdout.wait_readable(timeout_seconds)

        @stdout.gets
      end
    end
  end
end
