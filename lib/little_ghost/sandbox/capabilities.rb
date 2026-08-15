# frozen_string_literal: true

module LittleGhost
  class Sandbox
    # Describes the operations, network modes, and isolation mechanism a Sandbox
    # backend implements. Capabilities are immutable and safe to expose to
    # tools, but are not a security certification of the surrounding deployment.
    class Capabilities
      DEFAULT_FEATURES = %i[filesystem_read filesystem_list process_execute].freeze # :nodoc:
      NETWORK_MODES = %i[inherit none allowlist].freeze # :nodoc:
      ALIASES = { # :nodoc:
        read: :filesystem_read,
        list: :filesystem_list,
        write: :filesystem_write,
        replace: :filesystem_replace,
        execute: :process_execute,
        spawn: :process_spawn
      }.freeze

      def self.normalize(feature) = ALIASES.fetch(feature.to_sym, feature.to_sym) # :nodoc:

      # Builds a capability report from feature names and supported network
      # modes. +isolation+ is descriptive and does not itself grant an operation
      # or establish a complete trust boundary.
      def initialize(features: DEFAULT_FEATURES, network_modes: [:inherit], isolation: :none)
        @features = Array(features).map(&:to_sym).uniq.freeze
        @network_modes = Array(network_modes).map(&:to_sym).uniq.freeze
        invalid_modes = @network_modes - NETWORK_MODES
        raise ArgumentError, "unsupported network modes: #{invalid_modes.to_a.join(", ")}" unless invalid_modes.empty?

        @isolation = isolation.to_sym
        freeze
      end

      # Operation names implemented by the backend.
      attr_reader :features
      # Network modes the backend can enforce.
      attr_reader :network_modes
      # Descriptive isolation mechanism, such as +:none+ or +:container+.
      attr_reader :isolation

      # Indicates whether +feature+ is available. For +:network+, +value+
      # selects the requested mode.
      def supports?(feature, value = nil)
        feature = self.class.normalize(feature)
        return network_modes.include?(value.to_sym) if feature == :network && value
        return !network_modes.empty? if feature == :network

        features.include?(feature)
      end

      # Equivalent to #supports?.
      alias_method :include?, :supports?

      # Produces a capability set no broader than both operands.
      def intersect(other)
        self.class.new(
          features: features & other.features,
          network_modes: network_modes & other.network_modes,
          isolation:
        )
      end
    end
  end
end
