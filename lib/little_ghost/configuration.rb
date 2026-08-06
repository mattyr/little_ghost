# frozen_string_literal: true

require "logger"
require "pathname"

module LittleGhost
  class Configuration
    CONFIGURATION_KEYS = %i[invocation models default_model instrumentation service_name].freeze
    DEFAULT_PROMPT_PATHS = ["app/prompts"].freeze
    DEFAULT_SKILL_PATHS = ["app/skills"].freeze

    CONFIGURATION_KEYS.each do |name|
      define_method(name) do |value = :__read__|
        return configuration_values[name] if value == :__read__

        configuration_values[name] = (name == :default_model) ? value.to_s : value
      end
    end

    CONFIGURATION_KEYS.each do |name|
      define_method("#{name}=") { |value| public_send(name, value) }
    end

    def initialize(values = {})
      @configuration_values = {
        prompt_paths: DEFAULT_PROMPT_PATHS.dup,
        skill_paths: DEFAULT_SKILL_PATHS.dup,
        skill_resource_root: nil,
        instruments: []
      }.merge(values)
      @configuration_values[:prompt_paths] = Array(@configuration_values[:prompt_paths]).dup
      @configuration_values[:skill_paths] = Array(@configuration_values[:skill_paths]).dup
      @configuration_values[:instruments] = Array(@configuration_values[:instruments]).dup
    end

    def configure
      yield self if block_given?
      self
    end

    def [](name)
      configuration_values.fetch(name.to_sym)
    end

    def []=(name, value)
      configuration_values[name.to_sym] = value
    end

    def root=(value)
      root(value)
    end

    def instrument(installer, **options)
      configuration_values[:instruments] << [installer, options]
      installer
    end

    def session_store(value = :__read__, &factory)
      return configuration_values[:session_store] if value == :__read__ && !factory

      raise ArgumentError, "Provide a session store or a block, not both" if value != :__read__ && factory

      configuration_values[:session_store] = factory || value
    end

    def session_actor(value = :__read__, &resolver)
      return configuration_values[:session_actor] if value == :__read__ && !resolver

      raise ArgumentError, "Provide a session actor resolver or a block, not both" if value != :__read__ && resolver

      configured = resolver || value
      raise ArgumentError, "session_actor must be callable" unless configured.respond_to?(:call)

      configuration_values[:session_actor] = configured
    end

    def root(value = :__read__)
      if value != :__read__
        return configuration_values[:root] = canonical_root(value)
      end

      configured = configuration_values[:root]
      configured ? canonical_root(configured) : inferred_root
    end

    def prompt_paths = configuration_values[:prompt_paths]

    def prompt_paths=(value)
      configuration_values[:prompt_paths] = Array(value)
    end

    def skill_paths = configuration_values[:skill_paths]

    def skill_paths=(value)
      configuration_values[:skill_paths] = Array(value)
    end

    def skill_resource_root = configuration_values[:skill_resource_root]

    def skill_resource_root=(value)
      configuration_values[:skill_resource_root] = value
    end

    def settings(root: nil)
      requested_root = root && canonical_root(root)
      values = configuration_values.dup
      values[:prompt_paths] = Array(values[:prompt_paths]).dup
      values[:skill_paths] = Array(values[:skill_paths]).dup
      values[:instruments] = Array(values[:instruments]).dup
      values[:root] = requested_root || values[:root] || self.root
      values
    end

    def load_file!(root: nil)
      requested_root = canonical_root(root || self.root)
      (@configuration_file_mutex ||= Mutex.new).synchronize do
        if @configuration_file_root
          return self if @configuration_file_root == requested_root

          raise ConfigurationError, "configuration file is already loaded for #{@configuration_file_root}"
        end

        path = File.join(requested_root, "config/little_ghost.rb")
        LittleGhost.with_configuration(self) { Kernel.load(path) } if File.file?(path)
        @configuration_file_root = requested_root
      end

      self
    end

    private

    attr_reader :configuration_values

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
