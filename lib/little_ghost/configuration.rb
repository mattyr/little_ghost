# frozen_string_literal: true

require "logger"
require "pathname"

module LittleGhost
  class Configuration
    class << self
      CONFIGURATION_KEYS = %i[agent entrypoint invocation models default_model instrumentation service_name].freeze
      CONFIGURATION_KEYS.each do |name|
        define_method(name) do |value = :__read__|
          return configuration_values[name] if value == :__read__

          ensure_not_loaded!
          configuration_values[name] = (name == :default_model) ? value.to_s : value
        end
      end

      def configuration_values
        @configuration_values ||= {components: [], instruments: []}
      end

      def configure(&block)
        yield self if block
        self
      end

      def configuration = self

      def [](name)
        configuration_values.fetch(name.to_sym)
      end

      def []=(name, value)
        ensure_not_loaded!
        configuration_values[name.to_sym] = value
      end

      CONFIGURATION_KEYS.each do |name|
        define_method("#{name}=") { |value| public_send(name, value) }
      end

      def root=(value)
        root(value)
      end

      def instrument(installer, **options)
        ensure_not_loaded!
        configuration_values[:instruments] << [installer, options]
        installer
      end

      def session_store(value = :__read__, &factory)
        return configuration_values[:session_store] if value == :__read__ && !factory

        ensure_not_loaded!
        raise ArgumentError, "Provide a session store or a block, not both" if value != :__read__ && factory

        configuration_values[:session_store] = factory || value
      end

      def session_actor(value = :__read__, &resolver)
        return configuration_values[:session_actor] if value == :__read__ && !resolver

        ensure_not_loaded!
        raise ArgumentError, "Provide a session actor resolver or a block, not both" if value != :__read__ && resolver

        configured = resolver || value
        unless configured.respond_to?(:call)
          raise ArgumentError, "session_actor must be callable"
        end

        configuration_values[:session_actor] = configured
      end

      def root(value = :__read__)
        if value != :__read__
          ensure_not_loaded!
          return configuration_values[:root] = canonical_root(value)
        end

        configured = configuration_values[:root]
        configured ? canonical_root(configured) : inferred_root
      end

      def component(value = nil, root: nil)
        ensure_not_loaded!
        configured = value || Component.new(root: root)
        raise ArgumentError, "component must be a LittleGhost::Component" unless configured.is_a?(Component)

        configuration_values[:components] << configured
        configured
      end

      def settings(root: nil)
        requested_root = root && canonical_root(root)
        if @settings
          if requested_root && @settings.fetch(:root) != requested_root
            raise ConfigurationError, "configuration is already materialized for #{@settings.fetch(:root)}"
          end
          return @settings
        end

        (@settings_mutex ||= Mutex.new).synchronize do
          if @settings
            if requested_root && @settings.fetch(:root) != requested_root
              raise ConfigurationError, "configuration is already materialized for #{@settings.fetch(:root)}"
            end
            return @settings
          end

          values = configuration_values.dup
          values[:components] = Array(values[:components]).dup
          values[:root] = requested_root || values[:root] || self.root
          @settings = Support.immutable(values)
        end
      end

      def load_file!(root: nil)
        requested_root = canonical_root(root || self.root)
        (@configuration_file_mutex ||= Mutex.new).synchronize do
          if @configuration_file_root
            return self if @configuration_file_root == requested_root

            raise ConfigurationError, "configuration file is already loaded for #{@configuration_file_root}"
          end

          path = File.join(requested_root, "config/little_ghost.rb")
          require path if File.file?(path)
          @configuration_file_root = requested_root
        end

        self
      end

      def load(root: nil)
        load_file!(root:)
      end

      private

      def ensure_not_loaded!
        raise ConfigurationError, "#{self} is already loaded" if @settings
      end

      def inferred_root
        canonical_root(Dir.pwd)
      end

      def canonical_root(value)
        path = Pathname.new(File.realpath(File.expand_path(value)))
        raise ConfigurationError, "application root must be a directory" unless path.directory?

        path
      rescue Errno::ENOENT
        raise ConfigurationError, "application root must exist"
      end
    end
  end
end
