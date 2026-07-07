# frozen_string_literal: true

require "test_helper"

module Yorishiro
  module E2E
    class MockProvider < Provider::Base
      attr_accessor :responses, :tool_call_responses

      def initialize
        super(api_key: "mock")
        @responses = []
        @tool_call_responses = []
        @call_index = 0
      end

      def self.supported_models
        ["mock-model"]
      end

      def chat(_conversation, tools: [], &block) # rubocop:disable Lint/UnusedMethodArgument
        if @tool_call_responses.any? && @call_index < @tool_call_responses.length
          response = @tool_call_responses[@call_index]
          @call_index += 1
          block&.call(response[:content]) if response[:content] && !response[:content].empty?
          return response
        end

        text = @responses.shift || "Mock response from Yorishiro"
        block&.call(text)
        @call_index += 1
        { content: text, tool_calls: [] }
      end

      private

      def default_model
        "mock-model"
      end
    end

    class ScriptRunner
      attr_reader :conversation, :output

      def initialize(provider: nil)
        Yorishiro.reset!

        @provider = provider || MockProvider.new
        @config = Yorishiro.configuration
        @config.use(provider: :anthropic, api_key: "mock")
        @conversation = Yorishiro::Conversation.new(system_prompt: nil)
        @output = StringIO.new
        @tool_calls = []
        @permission_asked = false
      end

      def with_tools(*tools)
        tools.each { |t| @config.allow_tool(t) }
        self
      end

      def input(text)
        @conversation.add_message(:user, text)

        result = @provider.chat(@conversation, tools: @config.tool_definitions)
        content = result[:content]
        tool_calls = result[:tool_calls]

        @output.print(content)
        @conversation.add_message(:assistant, content, tool_calls: tool_calls.empty? ? nil : tool_calls)

        if tool_calls.any?
          tool_calls.each do |tc|
            tool = @config.find_tool(tc[:name])
            next unless tool

            @tool_calls << tc[:name]
            output = tool.execute(**symbolize_keys(tc[:arguments]))
            @conversation.add_tool_result(tool_call_id: tc[:id], content: output)
          end
        end

        self
      end

      def assert_output_contains(text)
        assert_includes @output.string, text
        self
      end

      def assert_conversation_length(expected)
        assert_equal expected, @conversation.length
        self
      end

      def assert_last_role(role)
        assert_equal role, @conversation.last_role
        self
      end

      def assert_tool_called(name)
        assert_includes @tool_calls, name
        self
      end

      private

      def symbolize_keys(hash)
        hash.transform_keys(&:to_sym)
      end

      def assert_includes(collection, obj)
        raise "Expected #{collection.inspect} to include #{obj.inspect}" unless collection.include?(obj)
      end

      def assert_equal(expected, actual)
        raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
      end
    end

    class PlanRunner
      attr_reader :conversation, :output

      def initialize(provider: nil)
        @provider = provider || MockProvider.new
        @config = Yorishiro.configuration
        @config.use(provider: :anthropic, api_key: "mock") unless @config.provider_name
        @conversation = Yorishiro::Conversation.new(system_prompt: nil)
        @output = StringIO.new
      end

      def input(text)
        @conversation.add_message(:user, text)

        exit_tool = Yorishiro::Tools::ExitPlanMode.new
        plan_tools = @config.read_only_tool_definitions + [exit_tool.definition]

        loop do
          result = @provider.chat(@conversation, tools: plan_tools)
          content = result[:content]
          tool_calls = result[:tool_calls]

          @output.print(content)
          @conversation.add_message(:assistant, content, tool_calls: tool_calls.empty? ? nil : tool_calls)

          break if tool_calls.empty?

          exit_call = tool_calls.find { |tc| tc[:name] == exit_tool.name }
          if exit_call
            @conversation.add_tool_result(tool_call_id: exit_call[:id], content: "Plan presented to the user for approval.")
            break
          end

          tool_calls.each do |tc|
            tool = @config.find_tool(tc[:name])
            unless tool
              @conversation.add_tool_result(tool_call_id: tc[:id], content: "Error: Unknown tool '#{tc[:name]}'")
              next
            end

            output = tool.execute(**symbolize_keys(tc[:arguments]))
            @conversation.add_tool_result(tool_call_id: tc[:id], content: output)
          end
        end

        self
      end

      private

      def symbolize_keys(hash)
        hash.transform_keys(&:to_sym)
      end
    end
  end
end
