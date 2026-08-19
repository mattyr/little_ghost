# frozen_string_literal: true

module LittleGhost
  module MCP
    # Toolset gives an Agent a reusable MCP server declaration. Subclass it once,
    # then add that class through the ordinary Agent tools DSL.
    #
    #   class HelpCenterTools < LittleGhost::MCP::Toolset
    #     endpoint "https://mcp.example/rpc"
    #     headers { {"Authorization" => "Bearer #{ENV.fetch("MCP_ACCESS_TOKEN")}"} }
    #     prefix "help_center"
    #     expose "search", "fetch"
    #   end
    #
    #   class CustomerSupportAgent < LittleGhost::Agent
    #     tools HelpCenterTools
    #   end
    #
    # The declaration is shared, but its connection state is not. LittleGhost
    # creates a new HTTPTransport and Client whenever it materializes an Agent's
    # tools, so negotiated MCP sessions are not shared between Agent runs.
    #
    # A +headers+ block is evaluated at that point. A block with one parameter
    # receives the current Run, which lets an application select credentials for
    # the authenticated caller. The MCP server remains responsible for checking
    # what those credentials may access. +expose+ limits which advertised tools
    # are available to the Agent; it does not grant access at the server.
    #
    # Use HTTPTransport and Client directly when an application needs a custom
    # transport or definition filter.
    class Toolset
      extend Support::ClassAttributes

      TRANSPORT_OPTIONS = %i[timeout signer allow_insecure_http max_response_bytes].freeze # :nodoc:
      UNSET = Object.new.freeze # :nodoc:

      class_attribute :endpoint_value
      class_attribute :headers_value, default: {}.freeze
      class_attribute :headers_endpoint_value
      class_attribute :prefix_value
      class_attribute :exposed_tool_names_value
      class_attribute :transport_options_value, default: {}.freeze

      class << self
        # :call-seq:
        #   endpoint() -> String, nil
        #   endpoint(url, **transport_options) -> String
        #
        # Sets the MCP Streamable HTTP URL. Supported transport options are
        # +timeout+, +signer+, +allow_insecure_http+, and +max_response_bytes+.
        def endpoint(*values, **options)
          return endpoint_value if values.empty? && options.empty?

          raise ArgumentError, "endpoint requires one URL" unless values.length == 1

          unknown = options.keys - TRANSPORT_OPTIONS
          raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?

          self.endpoint_value = String(values.fetch(0)).freeze
          self.transport_options_value = options.dup.freeze
          endpoint_value
        end

        # :call-seq:
        #   headers() -> Hash, Proc
        #   headers(values) -> Hash
        #   headers { |run| ... } -> Proc
        #
        # Sets static request headers or a resolver evaluated for each Agent.
        # A resolver with one parameter receives the current Run.
        #
        # Declare +endpoint+ before +headers+. Toolset settings are inherited;
        # when a subclass changes its endpoint, it must also redeclare headers.
        # This prevents credentials configured for one server from being sent to
        # another.
        def headers(value = UNSET, &resolver)
          return headers_value if value.equal?(UNSET) && !resolver
          raise ArgumentError, "provide headers or a block, not both" unless value.equal?(UNSET) || !resolver
          raise ConfigurationError, "#{toolset_name} must declare an MCP endpoint before headers" unless endpoint_value

          configured = resolver || value
          unless configured.is_a?(Hash) || configured.respond_to?(:call)
            raise ArgumentError, "headers must be a hash or callable"
          end

          self.headers_value = configured.is_a?(Hash) ? normalize_headers(configured) : configured
          self.headers_endpoint_value = endpoint_value
          headers_value
        end

        # :call-seq:
        #   prefix() -> String, nil
        #   prefix(value) -> String
        #
        # Adds +value+ to every model-visible MCP tool name.
        def prefix(*values)
          return prefix_value if values.empty?

          raise ArgumentError, "prefix requires one value" unless values.length == 1

          self.prefix_value = String(values.fetch(0)).freeze
        end

        # :call-seq:
        #   expose() -> Array<String>, nil
        #   expose(*names) -> Array<String>
        #
        # Limits this Toolset to the named MCP tools. Without +expose+, every
        # valid tool advertised by the server is available.
        def expose(*names)
          return exposed_tool_names_value if names.empty?

          values = names.flatten.map { |name| String(name).freeze }.uniq.freeze
          raise ArgumentError, "expose requires at least one tool name" if values.empty?

          self.exposed_tool_names_value = values
        end

        # :call-seq:
        #   tools(binding) -> Array<Class<LittleGhost::Tool>>
        #
        # Returns generated MCP-backed Tool classes. Agent and ToolRegistry call
        # this provider hook automatically for a Toolset named in the Agent
        # +tools+ DSL, then ToolRegistry instantiates those classes with +binding+;
        # applications normally do not call it.
        #
        # Raises ConfigurationError when no endpoint is declared, when inherited
        # headers belong to a different endpoint, or when resolved headers are
        # not a Hash.
        def tools(binding)
          url = endpoint_value
          raise ConfigurationError, "#{toolset_name} must declare an MCP endpoint" if url.nil? || url.empty?

          allowed = exposed_tool_names_value
          definition_filter = if allowed
            ->(definition) { allowed.include?(definition.fetch("name")) }
          end
          transport = HTTPTransport.new(
            url:,
            headers: resolved_headers(binding.run),
            **transport_options_value
          )
          client = Client.new(
            transport:,
            name: toolset_name,
            prefix: prefix_value,
            definition_filter:
          )
          context = binding.run.context if binding.run&.respond_to?(:context)
          client.tools(context:)
        end

        private

        def resolved_headers(run)
          if headers_endpoint_value && headers_endpoint_value != endpoint_value
            raise ConfigurationError, "#{toolset_name} must redeclare headers after changing its MCP endpoint"
          end

          value = headers_value
          if value.respond_to?(:call)
            parameters = value.is_a?(Proc) ? value.parameters : value.method(:call).parameters
            value = parameters.empty? ? value.call : value.call(run)
          end
          raise ConfigurationError, "#{toolset_name} headers must resolve to a hash" unless value.is_a?(Hash)

          normalize_headers(value)
        end

        def normalize_headers(headers)
          headers.each_with_object({}) do |(name, value), normalized|
            normalized[String(name).dup.freeze] = String(value).dup.freeze
          end.freeze
        end

        def toolset_name
          name || "MCP Toolset"
        end
      end
    end
  end
end
