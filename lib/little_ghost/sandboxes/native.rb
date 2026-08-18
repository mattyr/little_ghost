# frozen_string_literal: true

module LittleGhost
  module Sandboxes
    # Selects the operating system's built-in LittleGhost isolation backend.
    # Selection fails closed on unsupported platforms and never falls back to
    # unrestricted host execution.
    class Native < Sandbox
      def self.probe(platform: RUBY_PLATFORM, **options)
        implementation = if platform.include?("darwin")
          Seatbelt
        elsif platform.include?("linux")
          Bubblewrap
        else
          return {available: false, reason: "native sandboxing is unavailable on #{platform}", capabilities: Capabilities.new(features: [], network_modes: [])}
        end
        implementation.probe(platform:, **options)
      end

      def initialize(workspace:, platform: RUBY_PLATFORM, **options)
        implementation = if platform.include?("darwin")
          Seatbelt
        elsif platform.include?("linux")
          Bubblewrap
        else
          raise UnsupportedPlatformError, "native sandboxing is unavailable on #{platform}"
        end
        @backend = implementation.new(workspace:, platform:, **options)
        super(workspace:, policy: @backend.policy, limits: @backend.limits)
      end

      def effective_policy = @backend.effective_policy
      def capabilities = @backend.capabilities
      def open(run: nil) = @backend.open(run:)
      def close = @backend.close
      def read(...) = @backend.read(...)
      def list(...) = @backend.list(...)
      def write(...) = @backend.write(...)
      def replace(...) = @backend.replace(...)
      def execute_program(...) = @backend.execute_program(...)
      def start_program(...) = @backend.start_program(...)
      def scope(...) = @backend.scope(...)
    end
  end
end

LittleGhost::Sandbox.register_provider(:native, LittleGhost::Sandboxes::Native)
