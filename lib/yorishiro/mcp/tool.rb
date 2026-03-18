# frozen_string_literal: true

module Yorishiro
  module MCP
    class Tool < Yorishiro::Tool
      attr_reader :mcp_tool, :client, :server_name

      def initialize(mcp_tool:, client:, server_name:)
        super()
        @mcp_tool = mcp_tool
        @client = client
        @server_name = server_name
      end

      def name
        @mcp_tool.name
      end

      def description
        @mcp_tool.description || "MCP tool from #{@server_name}"
      end

      def parameters
        @mcp_tool.input_schema || { type: "object", properties: {}, required: [] }
      end

      def execute(**params)
        response = @client.call_tool(tool: @mcp_tool, arguments: params)

        content = response.dig("result", "content")
        return response.to_s unless content

        content.map { |c| c["text"] || c.to_s }.join("\n")
      end

      def permission_check(_arguments)
        :ask
      end
    end
  end
end
