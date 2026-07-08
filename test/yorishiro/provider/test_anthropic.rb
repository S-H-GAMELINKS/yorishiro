# frozen_string_literal: true

require "test_helper"

class TestProviderAnthropic < Minitest::Test
  def setup
    @provider = Yorishiro::Provider::Anthropic.new(api_key: "test-key")
    @conversation = Yorishiro::Conversation.new(system_prompt: "You are helpful.")
    @conversation.add_message(:user, "Hello")
  end

  def test_supported_models
    models = Yorishiro::Provider::Anthropic.supported_models
    assert_includes models, "claude-sonnet-4-20250514"
    assert_includes models, "claude-opus-4-20250514"
  end

  def test_default_model
    assert_equal "claude-sonnet-4-20250514", @provider.model_name
  end

  def test_chat_sends_correct_headers
    stub_anthropic_stream("Hello!")

    @provider.chat(@conversation)

    assert_requested(:post, "https://api.anthropic.com/v1/messages") do |req|
      req.headers["X-Api-Key"] == "test-key" &&
        req.headers["Anthropic-Version"] == "2023-06-01" &&
        req.headers["Content-Type"] == "application/json"
    end
  end

  def test_chat_sends_system_prompt_in_body
    stub_anthropic_stream("Hello!")

    @provider.chat(@conversation)

    assert_requested(:post, "https://api.anthropic.com/v1/messages") do |req|
      body = JSON.parse(req.body)
      body["system"] == "You are helpful."
    end
  end

  def test_chat_returns_text
    stub_anthropic_stream("Hello there!")

    result = @provider.chat(@conversation)
    assert_equal "Hello there!", result[:content]
    assert_empty result[:tool_calls]
  end

  def test_chat_streams_text
    stub_anthropic_stream("Hello!")

    chunks = []
    @provider.chat(@conversation) { |text| chunks << text }
    assert_equal ["Hello!"], chunks
  end

  def test_chat_with_tool_calls
    stub_anthropic_tool_call("read_file", { "path" => "/tmp/test" })

    result = @provider.chat(@conversation)
    assert_equal 1, result[:tool_calls].length
    assert_equal "read_file", result[:tool_calls][0][:name]
    assert_equal({ "path" => "/tmp/test" }, result[:tool_calls][0][:arguments])
  end

  def test_chat_401_error
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 401, body: "Unauthorized")

    assert_raises(Yorishiro::ProviderError) { @provider.chat(@conversation) }
  end

  def test_chat_429_error
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 429, body: "Rate limited")

    assert_raises(Yorishiro::ProviderError) { @provider.chat(@conversation) }
  end

  def test_chat_500_error
    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 500, body: "Internal Server Error")

    assert_raises(Yorishiro::ProviderError) { @provider.chat(@conversation) }
  end

  def test_chat_reports_usage
    body = sse_events([
                        { event: "message_start",
                          data: { type: "message_start", message: { usage: { input_tokens: 55, output_tokens: 1 } } } },
                        { event: "content_block_start",
                          data: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } },
                        { event: "content_block_delta",
                          data: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "hi" } } },
                        { event: "content_block_stop", data: { type: "content_block_stop", index: 0 } },
                        { event: "message_delta", data: { type: "message_delta", usage: { output_tokens: 9 } } },
                        { event: "message_stop", data: { type: "message_stop" } }
                      ])

    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })

    result = @provider.chat(@conversation)
    assert_equal({ input: 55, output: 9 }, result[:usage])
  end

  private

  def stub_anthropic_stream(text)
    body = sse_events([
                        { event: "content_block_start",
                          data: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } },
                        { event: "content_block_delta",
                          data: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: text } } },
                        { event: "content_block_stop", data: { type: "content_block_stop", index: 0 } },
                        { event: "message_stop", data: { type: "message_stop" } }
                      ])

    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })
  end

  def stub_anthropic_tool_call(name, arguments)
    body = sse_events([
                        { event: "content_block_start",
                          data: { type: "content_block_start", index: 0,
                                  content_block: { type: "tool_use", id: "toolu_test", name: name } } },
                        { event: "content_block_delta",
                          data: { type: "content_block_delta", index: 0,
                                  delta: { type: "input_json_delta", partial_json: JSON.generate(arguments) } } },
                        { event: "content_block_stop", data: { type: "content_block_stop", index: 0 } },
                        { event: "message_stop", data: { type: "message_stop" } }
                      ])

    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })
  end

  def sse_events(events)
    events.map { |e| "event: #{e[:event]}\ndata: #{JSON.generate(e[:data])}\n\n" }.join
  end
end
