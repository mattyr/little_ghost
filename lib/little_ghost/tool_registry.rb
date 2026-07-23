# frozen_string_literal: true

module LittleGhost
  class ToolRegistry
    MAX_NAME_LENGTH = 64
    NAME_PATTERN = /\A[a-zA-Z0-9_-]+\z/

    include Enumerable

    def initialize(tools = [], run: nil)
      @tools = {}
      @run = run
      @closed = false
      @closed_tool_ids = {}
      supplied_instances = Array(tools).flatten.grep(Tool).uniq(&:object_id)
      add(tools)
    rescue => error
      begin
        close
      rescue
        nil
      end
      begin
        close_instances(supplied_instances)
      rescue
        nil
      end
      raise error
    end

    def register(tool, replace: false)
      raise Error, "Tool registry is closed" if @closed

      instances = []
      existing_ids = @tools.each_value.to_h { |instance| [instance.object_id, true] }
      resolve(tool, instances)
      seen = []
      names = instances.map do |instance|
        raise ConfigurationError, "Tools must inherit from LittleGhost::Tool" unless instance.is_a?(Tool)

        name = instance.class.tool_name
        validate_name!(name)
        validate_description!(instance.class.description)
        raise ConfigurationError, "Tool name collision: #{name}" if @tools.key?(name) && !replace
        raise ConfigurationError, "Tool name collision: #{name}" if seen.include?(name)

        seen << name
        name
      end

      replaced = names.filter_map { |name| @tools[name] if replace }
      names.zip(instances).each { |name, instance| @tools[name] = instance }
      close_instances(replaced)
      self
    rescue => error
      begin
        close_instances(instances.to_a.reject { |instance| existing_ids&.key?(instance.object_id) })
      rescue
        nil
      end
      raise error
    end

    def close
      return if @closed

      @closed = true
      close_instances(@tools.each_value.to_a)
    end

    def fetch(name)
      @tools.fetch(name.to_s) { raise ToolError, "Unknown tool: #{name}" }
    end

    def each(&block)
      @tools.each_value(&block)
    end

    def specifications
      map { |tool| tool.class.specification }.freeze
    end

    def names
      @tools.keys.freeze
    end

    private

    def add(values)
      Array(values).flatten.compact.each { |value| register(value) }
    end

    def close_instances(instances)
      first_error = nil
      instances.reverse_each do |instance|
        next unless instance.respond_to?(:close)
        next if @closed_tool_ids[instance.object_id]

        @closed_tool_ids[instance.object_id] = true
        instance.close
      rescue => error
        first_error ||= error
      end
      raise first_error if first_error
    end

    def resolve(value, instances)
      if value.is_a?(Proc)
        resolved = value.parameters.empty? ? value.call : value.call(@run)
        return resolve(resolved, instances)
      end
      if value.is_a?(Array)
        value.flatten.compact.each { |child| resolve(child, instances) }
      elsif value.is_a?(Class) && value <= Tool
        instances << value.new(run: @run)
      else
        instances << value
      end
      instances
    end

    def validate_name!(name)
      if name.nil? || name.empty?
        raise ConfigurationError, "Tool name is required"
      elsif name.length > MAX_NAME_LENGTH
        raise ConfigurationError, "Tool name cannot exceed #{MAX_NAME_LENGTH} characters: #{name}"
      elsif !NAME_PATTERN.match?(name)
        raise ConfigurationError, "Tool name may contain only letters, numbers, underscores, and hyphens: #{name}"
      end
    end

    def validate_description!(description)
      if description.nil? || description.empty?
        raise ConfigurationError, "Tool description is required"
      end
    end
  end
end
