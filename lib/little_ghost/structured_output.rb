# frozen_string_literal: true

module LittleGhost
  module StructuredOutput # :nodoc: all
    STRATEGIES = %i[auto provider tool].freeze

    class Strategy
      attr_reader :configuration

      def initialize(configuration)
        @configuration = configuration
      end

      def schema_name = configuration.fetch(:name)
      def provider? = false
      def tool? = false
      def tools(ordinary_tools) = ordinary_tools
      def output_schema = nil
      def tool_choice(repair:) = nil
      def required_capabilities = [].freeze
    end

    class ProviderStrategy < Strategy
      def provider? = true
      def output_schema = configuration
      def required_capabilities = [:native_structured_output].freeze
    end

    class ToolStrategy < Strategy
      def tool? = true

      def tools(ordinary_tools)
        [*ordinary_tools, result_tool].freeze
      end

      def tool_choice(repair:)
        repair ? {name: schema_name}.freeze : :required
      end

      def required_capabilities = %i[tools tool_choice].freeze

      def result_tool
        {
          name: schema_name,
          description: configuration[:description] ||
            "Submit the final structured result. Call this tool only as the final action.",
          input_schema: configuration.fetch(:schema),
          strict: true
        }.freeze
      end
    end

    module_function

    def resolve(configuration, model:, ordinary_tools:)
      return unless configuration

      requested = configuration.fetch(:strategy, :auto).to_sym
      capabilities = if model.respond_to?(:capabilities)
        model.capabilities
      else
        ModelCapabilities.legacy
      end
      strategy = case requested
      when :auto then automatic_strategy(model, capabilities, ordinary_tools)
      when :provider
        validate_explicit_provider!(model, capabilities)
        ProviderStrategy
      when :tool
        validate_explicit_tool!(model, capabilities)
        ToolStrategy
      else
        raise ConfigurationError, "Unknown structured output strategy: #{requested}"
      end
      resolved = strategy.new(configuration)
      validate_tool_collision!(resolved, ordinary_tools)
      resolved
    end

    def validate_tool_collision!(strategy, ordinary_tools)
      return unless strategy.tool?
      return unless ordinary_tools.any? { |tool| tool.fetch(:name).to_s == strategy.schema_name }

      raise ConfigurationError, "Structured result tool name collides with an agent tool: #{strategy.schema_name}"
    end

    def automatic_strategy(model, capabilities, ordinary_tools)
      unless capabilities.known?
        raise ConfigurationError,
          "Structured output capabilities are unavailable for #{model_identity(model)}; " \
          "provide model capability metadata or select a strategy explicitly"
      end
      if capabilities.native_structured_output? && (ordinary_tools.empty? || capabilities.tools?)
        return ProviderStrategy
      end
      return ToolStrategy if capabilities.tools? && capabilities.tool_choice?

      raise ConfigurationError,
        "#{model_identity(model)} supports neither provider-native structured output nor reliable tool-based output"
    end
    private_class_method :automatic_strategy

    def validate_explicit_provider!(model, capabilities)
      return unless capabilities.known?
      return if capabilities.native_structured_output?

      raise ConfigurationError, "#{model_identity(model)} does not support provider-native structured output"
    end
    private_class_method :validate_explicit_provider!

    def validate_explicit_tool!(model, capabilities)
      return unless capabilities.known?
      return if capabilities.tools? && capabilities.tool_choice?

      raise ConfigurationError, "#{model_identity(model)} does not support reliable tool-based structured output"
    end
    private_class_method :validate_explicit_tool!

    def model_identity(model)
      provider = model.respond_to?(:provider_name) ? model.provider_name : model.class.name
      id = model.respond_to?(:id) ? model.id : nil
      [provider, id].compact.join("/")
    end
    private_class_method :model_identity
  end
end
