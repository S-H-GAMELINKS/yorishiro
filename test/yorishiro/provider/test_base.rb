# frozen_string_literal: true

require "test_helper"

class TestProviderBase < Minitest::Test
  def test_for_anthropic
    assert_equal Yorishiro::Provider::Anthropic, Yorishiro::Provider.for(:anthropic)
  end

  def test_for_open_ai
    assert_equal Yorishiro::Provider::OpenAI, Yorishiro::Provider.for(:open_ai)
  end

  def test_for_ollama
    assert_equal Yorishiro::Provider::Ollama, Yorishiro::Provider.for(:ollama)
  end

  def test_for_unknown
    assert_raises(Yorishiro::ProviderNotImplementedError) { Yorishiro::Provider.for(:unknown) }
  end

  def test_build
    Yorishiro.reset!
    config = Yorishiro::Configuration.new
    config.use(provider: :anthropic, api_key: "test-key")
    provider = Yorishiro::Provider.build(config)
    assert_instance_of Yorishiro::Provider::Anthropic, provider
  end

  def test_chat_not_implemented
    provider = Yorishiro::Provider::Base.new(api_key: "key", model: "test-model")
    assert_raises(Yorishiro::ProviderNotImplementedError) do
      provider.chat(Yorishiro::Conversation.new)
    end
  end

  def test_supported_models_not_implemented
    assert_raises(Yorishiro::ProviderNotImplementedError) do
      Yorishiro::Provider::Base.supported_models
    end
  end
end
