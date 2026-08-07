# frozen_string_literal: true

module LittleGhost
  class Sandbox
    Execution = Data.define(:stdout, :stderr, :exit_code, :error) do
      def initialize(stdout:, stderr:, exit_code:, error: nil)
        super
      end

      def success?
        error.nil? && exit_code&.zero?
      end
    end

    def initialize(workspace:)
      @workspace = workspace
    end

    attr_reader :workspace

    def open(run: nil)
      self
    end

    def writable? = false

    def read(path, context: nil)
      raise NotImplementedError, "#{self.class} does not support filesystem reads"
    end

    def list(path = ".", context: nil)
      raise NotImplementedError, "#{self.class} does not support filesystem listings"
    end

    def write(path, content, context: nil)
      raise NotImplementedError, "#{self.class} does not support filesystem writes"
    end

    def replace(path, old_text, new_text, context: nil)
      raise NotImplementedError, "#{self.class} does not support filesystem edits"
    end

    def execute(command, timeout:, context: nil, max_output_bytes: 1_000_000, **options)
      execute_program(
        ["/bin/sh", "-c", String(command)],
        timeout:,
        context:,
        max_output_bytes:,
        **options
      )
    end

    def execute_program(command, timeout:, context: nil, max_output_bytes: 1_000_000, environment: {}, inherit_environment: false)
      raise NotImplementedError, "#{self.class} does not support program execution"
    end

    def close
      nil
    end
  end
end
