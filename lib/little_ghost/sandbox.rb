# frozen_string_literal: true

module LittleGhost
  # A Sandbox decides what an agent may do with files and processes. Applications
  # can place that work on the host, in a container or VM, or behind a remote
  # execution service without changing their tools.
  #
  #   class ContainerSandbox < LittleGhost::Sandbox
  #     def initialize(workspace:, container:)
  #       super(workspace:)
  #       @container = container
  #     end
  #
  #     def read(path, context: nil)
  #       context&.check!
  #       @container.read(path)
  #     end
  #
  #     def execute_program(command, timeout:, context: nil, **)
  #       result = @container.run(
  #         command, timeout:, cancellation: context&.cancellation_token
  #       )
  #       Execution.new(**result)
  #     end
  #   end
  #
  # Implementations confine paths to #workspace, honor RunContext cancellation,
  # enforce time and output limits, and return
  # {Execution}[rdoc-ref:LittleGhost::Sandbox::Execution] from process
  # operations.
  class Sandbox
    # Contains captured process output, exit status, and an optional execution
    # error.
    Execution = Data.define(:stdout, :stderr, :exit_code, :error) do # :nodoc:
      def initialize(stdout:, stderr:, exit_code:, error: nil)
        super
      end

      def success?
        error.nil? && exit_code&.zero?
      end
    end

    # Carries captured process output, exit status, and an optional execution
    # error from Sandbox#execute or Sandbox#execute_program.
    class Execution < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(stdout:, stderr:, exit_code:, error: nil) -> Execution
      #
      # Collects the observable result of one sandbox process.

      ##
      # :attr_reader: stdout
      # Captured standard output, subject to the sandbox's output limit.

      ##
      # :attr_reader: stderr
      # Captured standard error, subject to the sandbox's output limit.

      ##
      # :attr_reader: exit_code
      # The child process exit status, when one is available.

      ##
      # :attr_reader: error
      # The execution error, or +nil+ when the process completed normally.

      ##
      # :method: success?
      # Indicates that no execution error occurred and the exit code is zero.
    end

    # Binds the sandbox to +workspace+.
    def initialize(workspace:)
      @workspace = workspace
    end

    # Workspace whose files and processes this sandbox governs.
    attr_reader :workspace

    # Opens any run-scoped resources and makes the sandbox ready for tools.
    def open(run: nil)
      self
    end

    # Indicates whether filesystem mutation is allowed.
    def writable? = false

    # Reads UTF-8 text at a workspace-relative +path+.
    def read(path, context: nil)
      raise NotImplementedError, "#{self.class} does not support filesystem reads"
    end

    # Lists entries at a workspace-relative directory +path+.
    def list(path = ".", context: nil)
      raise NotImplementedError, "#{self.class} does not support filesystem listings"
    end

    # Writes +content+ to a workspace-relative +path+.
    def write(path, content, context: nil)
      raise NotImplementedError, "#{self.class} does not support filesystem writes"
    end

    # Replaces one exact +old_text+ occurrence with +new_text+.
    def replace(path, old_text, new_text, context: nil)
      raise NotImplementedError, "#{self.class} does not support filesystem edits"
    end

    # Executes +command+ through +/bin/sh+.
    #
    # Prefer #execute_program for model-controlled arguments so shell syntax is
    # not interpreted.
    def execute(command, timeout:, context: nil, max_output_bytes: 1_000_000, **options)
      execute_program(
        ["/bin/sh", "-c", String(command)],
        timeout:,
        context:,
        max_output_bytes:,
        **options
      )
    end

    # Executes an argument vector without shell interpretation.
    #
    # Implementations must enforce +timeout+ and +max_output_bytes+. Environment
    # inheritance is disabled by default to avoid leaking process credentials.
    def execute_program(command, timeout:, context: nil, max_output_bytes: 1_000_000, environment: {}, inherit_environment: false)
      raise NotImplementedError, "#{self.class} does not support program execution"
    end

    # Releases sandbox resources. Runs close the sandbox before its workspace.
    def close
      nil
    end
  end
end
