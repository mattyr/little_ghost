# frozen_string_literal: true

module LittleGhost
  class ToolContext
    attr_reader :agent, :run, :runtime, :model, :workspace, :sandbox, :context, :storage

    def initialize(agent: nil, run: nil, runtime: nil, model: nil, workspace: nil, sandbox: nil, context: nil, storage: {})
      @agent = agent
      @run = run
      @runtime = runtime
      @model = model
      @workspace = workspace
      @sandbox = sandbox
      @context = context
      @storage = storage
    end

    def with(agent: self.agent, run: self.run, runtime: self.runtime, model: self.model,
      workspace: self.workspace, sandbox: self.sandbox, context: self.context, storage: self.storage)
      self.class.new(agent:, run:, runtime:, model:, workspace:, sandbox:, context:, storage:)
    end
  end
end
