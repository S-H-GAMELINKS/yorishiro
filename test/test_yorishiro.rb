# frozen_string_literal: true

require "test_helper"

class TestYorishiro < Minitest::Test
  def setup
    Yorishiro.reset!
  end

  def test_that_it_has_a_version_number
    refute_nil ::Yorishiro::VERSION
  end

  def test_error_hierarchy
    assert Yorishiro::ConfigurationError < Yorishiro::Error
    assert Yorishiro::ProviderError < Yorishiro::Error
    assert Yorishiro::ProviderNotImplementedError < Yorishiro::Error
    assert Yorishiro::ToolNotImplementedError < Yorishiro::Error
    assert Yorishiro::SkillNotImplementedError < Yorishiro::Error
  end

  def test_configuration_returns_singleton
    config1 = Yorishiro.configuration
    config2 = Yorishiro.configuration
    assert_same config1, config2
  end

  def test_reset_clears_configuration
    config1 = Yorishiro.configuration
    Yorishiro.reset!
    config2 = Yorishiro.configuration
    refute_same config1, config2
  end

  def test_configure_yields_configuration
    Yorishiro.configure do |config|
      config.use(provider: :anthropic, api_key: "test-key")
    end
    assert_equal :anthropic, Yorishiro.configuration.provider_name
  end
end
