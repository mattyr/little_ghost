# frozen_string_literal: true

module LittleGhost
  class ToolProvider
    def initialize(tool_context: ToolContext.new)
      @base_tool_context = tool_context
    end

    attr_reader :base_tool_context

    def tool_context = base_tool_context

    def agent = tool_context.agent
    def run = tool_context.run
    def runtime = tool_context.runtime
    def model = tool_context.model
    def workspace = tool_context.workspace
    def sandbox = tool_context.sandbox

    def tools
      raise NotImplementedError, "#{self.class} must implement #tools"
    end
  end
end
