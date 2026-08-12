# frozen_string_literal: true

module LittleGhost
  # ToolRegistry turns an agent's tool declarations into the exact set a model
  # can call during one run. It validates names, binds run collaborators, and
  # closes owned tool instances with the run.
  #
  #   binding = LittleGhost::Tool::Binding.new
  #   registry = LittleGhost::ToolRegistry.new([HelpCenterLookupTool], binding:)
  #   registry.names # => ["policy_lookup"]
  #
  # Entries may be Tool instances, Tool subclasses, nested arrays, or provider
  # classes that implement <tt>tools(binding)</tt>. Names must be unique, contain only
  # letters, numbers, underscores, or hyphens, and be at most 64 characters.
  # Owned tools are closed once in reverse order.
  class ToolRegistry
    MAX_NAME_LENGTH = 64 # :nodoc:
    NAME_PATTERN = /\A[a-zA-Z0-9_-]+\z/ # :nodoc:

    include Enumerable

    # Binds newly instantiated tools to +binding+.
    def initialize(tools = [], binding: Tool::Binding.new)
      @tools = {}
      @binding = binding
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

    # Registers +tool+ and returns +self+. When +replace+ is true, replaced owned tools
    # are closed after the new entries have been validated.
    def register(tool, replace: false)
      raise Error, "Tool registry is closed" if @closed

      instances = []
      existing_ids = @tools.each_value.to_h { |instance| [instance.object_id, true] }
      resolve(tool, instances, binding: @binding)
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

    # Closes every owned tool.
    def close
      return if @closed

      @closed = true
      close_instances(@tools.each_value.to_a)
    end

    # Finds the named tool or raises ToolError when it is unavailable.
    def fetch(name)
      @tools.fetch(name.to_s) { raise ToolError, "Unknown tool: #{name}" }
    end

    # Yields each registered tool instance.
    def each(&block)
      @tools.each_value(&block)
    end

    # Collects the frozen model-facing tool specifications.
    def specifications
      map { |tool| tool.class.specification }.freeze
    end

    # Lists the frozen model-visible tool names.
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
        next if @closed_tool_ids[instance.object_id]

        @closed_tool_ids[instance.object_id] = true
        instance.close
      rescue => error
        first_error ||= error
      end
      raise first_error if first_error
    end

    def resolve(value, instances, binding:)
      if value.is_a?(Array)
        value.flatten.compact.each { |child| resolve(child, instances, binding:) }
      elsif value.is_a?(Class) && value <= Tool
        instances << value.new(binding:)
      elsif value.is_a?(Class)
        resolve(value.tools(binding), instances, binding:)
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
