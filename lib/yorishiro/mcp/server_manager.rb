# frozen_string_literal: true

require "mcp"

module Yorishiro
  module MCP
    class ServerManager
      attr_reader :servers

      def initialize(server_configs:, configuration:)
        @server_configs = server_configs
        @configuration = configuration
        @servers = {}
      end

      def start_all
        @server_configs.each do |name, config|
          start_server(name, config)
        rescue StandardError => e
          warn "[MCP] Failed to start server '#{name}': #{e.message}"
        end
      end

      def stop_all
        @servers.each_value do |server|
          server[:transport].close
        rescue StandardError => e
          warn "[MCP] Error stopping server: #{e.message}"
        end
        @servers.clear
      end

      private

      def start_server(name, config)
        transport = ::MCP::Client::Stdio.new(
          command: config[:command],
          args: config.fetch(:args, []),
          env: config.fetch(:env, {}).compact
        )

        client = ::MCP::Client.new(transport: transport)
        client.connect

        mcp_tools = client.tools
        mcp_tools.each do |mcp_tool|
          wrapped = Yorishiro::MCP::Tool.new(
            mcp_tool: mcp_tool,
            client: client,
            server_name: name
          )
          @configuration.allow_tool(wrapped)
        end

        @servers[name] = { transport: transport, client: client }
      end
    end
  end
end
