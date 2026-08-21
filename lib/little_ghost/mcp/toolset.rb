# frozen_string_literal: true

module LittleGhost
  module MCP
    # Connects one MCP server to an Agent as a reusable Tool provider. Each Agent
    # run gets its own connection. +map_tool+ chooses and configures the generated
    # Tool classes; +map_result+ converts results that need application-specific
    # handling.
    #
    #   class HelpCenterTools < LittleGhost::MCP::Toolset
    #     connection url: "https://mcp.example/rpc", timeout: 20
    #   end
    #
    #   class CustomerSupportAgent < LittleGhost::Agent
    #     tools HelpCenterTools
    #   end
    class Toolset
      extend Support::ClassAttributes

      CONNECTION_OPTIONS = %i[url headers timeout signer allow_insecure_http max_response_bytes].freeze # :nodoc:
      UNSET = Object.new.freeze # :nodoc:

      class CallbackFailure < Error # :nodoc:
        attr_reader :original

        def initialize(original)
          @original = original
          super(original.message)
        end
      end

      class_attribute :connection_value
      class_attribute :tool_mapping_value
      class_attribute :result_mapping_value
      class_attribute :optional_value, default: false
      class_attribute :error_callback_value

      class << self
        # Declares a static connection Hash or a block called with the current
        # Tool::Binding. The Hash requires +url+ and may include
        # +headers+, +timeout+, +signer+, +allow_insecure_http+, and
        # +max_response_bytes+.
        #
        # :call-seq:
        #   connection() -> Hash, Proc, nil
        #   connection(values) -> Hash
        #   connection { |binding| ... } -> Proc
        def connection(value = UNSET, &resolver)
          return connection_value if value.equal?(UNSET) && !resolver
          raise ArgumentError, "provide a connection or a block, not both" unless value.equal?(UNSET) || !resolver

          configured = resolver || value
          unless configured.is_a?(Hash) || configured.respond_to?(:call)
            raise ArgumentError, "connection must be a hash or callable"
          end

          self.connection_value = configured.is_a?(Hash) ? normalize_connection(configured) : configured
        end

        # Maps each generated Tool class. The block receives +definition:+ and
        # +binding:+ keywords. Return the configured Tool class, or nil to omit
        # it. Changing Tool#tool_name does not change the operation name sent to
        # the MCP server.
        #
        # :call-seq:
        #   map_tool() -> Proc, nil
        #   map_tool { |tool_class, definition:, binding:| ... } -> Proc
        def map_tool(&mapping)
          return tool_mapping_value unless mapping

          self.tool_mapping_value = mapping
        end

        # Maps each immutable MCP::Result. The block receives +call:+ and
        # +binding:+ keywords and returns any Ruby value or Tool::Result.
        #
        # :call-seq:
        #   map_result() -> Proc, nil
        #   map_result { |result, call:, binding:| ... } -> Proc
        def map_result(&mapping)
          return result_mapping_value unless mapping

          self.result_mapping_value = mapping
        end

        # Makes expected provider and protocol discovery failures produce no
        # tools. Configuration, cancellation, deadline, and callback failures
        # still propagate.
        #
        # :call-seq:
        #   optional() -> true or false
        #   optional(value) -> true or false
        def optional(value = UNSET)
          return optional_value if value.equal?(UNSET)

          self.optional_value = !!value
        end

        # Observes an expected discovery failure caught by <tt>optional true</tt>.
        # Exceptions raised by this callback propagate.
        #
        # :call-seq:
        #   on_error() -> Proc, nil
        #   on_error { |error, binding:| ... } -> Proc
        def on_error(&callback)
          return error_callback_value unless callback

          self.error_callback_value = callback
        end

        # Generates Tool classes for an Agent's current binding.
        def tools(binding)
          options = resolved_connection(binding)
          context = binding.run&.context
          mapper = tool_mapping_value
          result_mapper = result_mapping_value
          options = connection_with_wrapped_signer(options)
          Instrumentation.instrument(:mcp_discovery, toolset: toolset_name) do |telemetry|
            client = Client.new(
              transport: HTTPTransport.new(**options),
              name: toolset_name,
              tool_mapper: mapper && lambda do |tool_class, definition:, binding:|
                invoke_application_callback do
                  mapper.call(tool_class, definition:, binding:)
                end
              end,
              result_mapper: result_mapper && lambda do |result, call:, binding:|
                result_mapper.call(result, call:, binding:)
              end
            )
            discovered = client.tools(context:, binding:)
            telemetry[:outcome] = :success
            telemetry[:tool_count] = discovered.length
            discovered
          end
        rescue CallbackFailure => error
          raise error.original
        rescue ProviderError, ProtocolError, ToolError => error
          raise unless optional_value

          error_callback_value&.call(error, binding:)
          []
        end

        private

        def resolved_connection(binding)
          configured = connection_value
          raise ConfigurationError, "#{toolset_name} must declare an MCP connection" unless configured

          value = if configured.respond_to?(:call)
            invoke_application_callback { configured.call(binding) }
          else
            configured
          end
          normalize_connection(value)
        end

        def normalize_connection(value)
          hash = Hash.try_convert(value)
          raise ConfigurationError, "#{toolset_name} connection must resolve to a hash" unless hash

          normalized = hash.each_with_object({}) do |(name, child), result|
            key = name.to_sym
            raise ConfigurationError, "#{toolset_name} connection contains duplicate #{key}" if result.key?(key)

            result[key] = child
          end
          unknown = normalized.keys - CONNECTION_OPTIONS
          unless unknown.empty?
            raise ConfigurationError, "#{toolset_name} connection contains unknown option #{unknown.first.inspect}"
          end
          url = normalized[:url]
          raise ConfigurationError, "#{toolset_name} connection must include a URL" if url.nil? || url.to_s.empty?

          normalized[:url] = String(url).freeze
          normalized[:headers] = normalize_headers(normalized.fetch(:headers, {}))
          normalized.freeze
        rescue NoMethodError
          raise ConfigurationError, "#{toolset_name} connection keys must be strings or symbols"
        end

        def normalize_headers(headers)
          headers.each_with_object({}) do |(name, value), normalized|
            normalized[String(name).dup.freeze] = String(value).dup.freeze
          end.freeze
        end

        def connection_with_wrapped_signer(options)
          signer = options[:signer]
          return options unless signer

          options.merge(
            signer: ->(request) { invoke_application_callback { signer.call(request) } }
          ).freeze
        end

        def invoke_application_callback
          yield
        rescue ProviderError, ProtocolError, ToolError => error
          raise CallbackFailure.new(error)
        end

        def toolset_name
          name || "MCP Toolset"
        end
      end
    end
  end
end
