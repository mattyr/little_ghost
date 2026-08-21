# frozen_string_literal: true

require "securerandom"

module LittleGhost
  class Assembly
    MAX_STEP_OUTPUT_BYTES = 64 * 1024 # :nodoc:
    MAX_STEP_EVENTS = 10_000 # :nodoc:
    MAX_STEP_EVENT_BYTES = 10 * 1024 * 1024 # :nodoc:

    Attempt = Data.define(:number, :status, :started_at, :finished_at, :usage, :error) do # :nodoc:
      def initialize(number:, status:, started_at:, finished_at:, usage: Usage.new, error: nil)
        super(number:, status: status.to_sym, started_at:, finished_at:, usage:, error: error&.to_s&.freeze)
      end
    end

    Step = Data.define( # :nodoc:
      :id, :parent_id, :predecessor_ids, :branch_id, :participant,
      :assembly_id, :assembly_kind, :status, :attempts, :usage, :output, :output_truncated
    ) do
      def initialize(id:, participant:, assembly_id:, assembly_kind:, status:, attempts:, usage:,
        parent_id: nil, predecessor_ids: [], branch_id: nil, output: nil, output_truncated: false)
        super(
          id: id.to_s.freeze,
          parent_id: parent_id&.to_s&.freeze,
          predecessor_ids: Array(predecessor_ids).map { |value| value.to_s.freeze }.freeze,
          branch_id: branch_id&.to_s&.freeze,
          participant: participant.to_s.freeze,
          assembly_id: assembly_id.to_s.freeze,
          assembly_kind: assembly_kind.to_sym,
          status: status.to_sym,
          attempts: Array(attempts).freeze,
          usage:,
          output:,
          output_truncated: output_truncated == true
        )
      end
    end

    # One bounded attempt to execute a child Assembly step.
    #
    # It records timing, normalized usage, terminal status, and a sanitized error
    # description suitable for the public coordination trajectory.
    class Attempt < Data # :doc:
      ##
      # :attr_reader: number
      # The one-based attempt number.

      ##
      # :attr_reader: status
      # The normalized terminal status for this attempt.

      ##
      # :attr_reader: started_at
      # The wall-clock start time.

      ##
      # :attr_reader: finished_at
      # The wall-clock finish time.

      ##
      # :attr_reader: usage
      # The Usage recorded by this attempt.

      ##
      # :attr_reader: error
      # A sanitized error description, or +nil+.
    end

    # One logical child execution in a composite Assembly result.
    #
    # Steps identify the participant, relationships to other steps, attempts,
    # usage, and a bounded semantic output. Use RunResult#trajectory for queries
    # over several steps.
    class Step < Data # :doc:
      ##
      # :attr_reader: id
      # The stable identifier for this step occurrence.

      ##
      # :attr_reader: parent_id
      # The containing step identifier for nested coordination, or +nil+.

      ##
      # :attr_reader: predecessor_ids
      # Step identifiers whose results led to this step.

      ##
      # :attr_reader: branch_id
      # The parallel branch identifier, or +nil+.

      ##
      # :attr_reader: participant
      # The participant name used by the parent Assembly.

      ##
      # :attr_reader: assembly_id
      # The invoked Assembly's stable identifier.

      ##
      # :attr_reader: assembly_kind
      # The invoked Assembly kind.

      ##
      # :attr_reader: status
      # The logical step's terminal status.

      ##
      # :attr_reader: attempts
      # Immutable Attempt values, including retries.

      ##
      # :attr_reader: usage
      # Usage accumulated across the step's attempts.

      ##
      # :attr_reader: output
      # The bounded semantic output retained for coordination inspection.

      ##
      # :attr_reader: output_truncated
      # Indicates that +output+ exceeded the public result limit.
    end

    # Immutable queries over the steps returned by one assembly invocation.
    class Trajectory
      include Enumerable

      # Immutable steps in execution order.
      attr_reader :steps

      # Builds query indexes for +steps+.
      def initialize(steps)
        @steps = Array(steps).freeze
        @by_id = @steps.to_h { |step| [step.id, step] }.freeze
        freeze
      end

      # Iterates through steps in execution order.
      def each(&block) = steps.each(&block)
      # Finds one step by its stable ID.
      def step(id) = @by_id[id.to_s]
      # Returns steps whose parent is +id+.
      def children(id) = steps.select { |item| item.parent_id == id.to_s }.freeze
      # Returns attempts belonging to one step.
      def attempts_for(id) = step(id)&.attempts || [].freeze

      # Returns declared predecessor-to-step ID pairs.
      def transitions
        steps.flat_map do |item|
          item.predecessor_ids.map { |predecessor| [predecessor, item.id].freeze }
        end.freeze
      end

      # Indicates whether attempts from two steps overlapped in time.
      def concurrent?(first_id, second_id)
        first = step(first_id)
        second = step(second_id)
        return false unless first && second

        first.attempts.any? do |left|
          second.attempts.any? do |right|
            left.started_at < right.finished_at && right.started_at < left.finished_at
          end
        end
      end
    end

    StepExecution = Data.define(:result, :step, :events, :transition) # :nodoc:

    private

    def execute_assembly_step(
      reference:,
      participant:,
      input:,
      history:,
      context:,
      cancellation_token:,
      deadline:,
      settings:,
      template_locals:,
      template_paths:,
      parent_operation_id:,
      policies: {},
      parent_id: nil,
      predecessor_ids: [],
      branch_id: nil,
      checkpoint: nil,
      build_options: {},
      step_id: SecureRandom.uuid
    )
      policy = normalize_step_policy(policies)
      attempts = []
      usage = Usage.new
      stream_path = agent_stream_path + [
        AgentStreamStep.build(
          assembly_id: self.class.assembly_id,
          assembly_kind: self.class.assembly_kind,
          participant:,
          step_id:,
          branch_id:
        )
      ]

      (policy.fetch(:retries) + 1).times do |index|
        attempt_number = index + 1
        started_at = Time.now
        child = if build_options.any? && runtime.respond_to?(:build_agent)
          build_stream_participant(:build_agent, reference, stream_path, **build_options)
        else
          build_stream_participant(:build_assembly, reference, stream_path, **build_options)
        end
        child_deadline = step_deadline(deadline, policy[:timeout])
        attempt_events = []
        attempt_event_bytes = 0
        result = nil
        attempt_usage = Usage.new
        begin
          with_active_assembly(child) do
            child.stream(
              input,
              history:,
              context: isolated_assembly_state(context),
              cancellation_token:,
              deadline: child_deadline,
              settings:,
              template_locals: template_locals.merge(runtime.template_locals(run:, agent: child)),
              template_paths:,
              parent_operation_id:,
              checkpoint:
            ).each do |event|
              result = event.data[:result] if event.type == :invocation_stop
              attempt_usage = event.data[:usage] || attempt_usage if event.type == :invocation_error
              attempt_event_bytes = buffer_assembly_event!(attempt_events, event, bytes: attempt_event_bytes)
            end
          end
          raise ProtocolError, "assembly step #{participant.inspect} did not return a result" unless result

          attempt_usage = result.usage
          usage += attempt_usage
          attempts << Attempt.new(
            number: attempt_number,
            status: :completed,
            started_at:,
            finished_at: Time.now,
            usage: attempt_usage
          )
          output, truncated = projected_step_output(result.output)
          nested_steps = reparent_steps(result.steps, step_id)
          step = Step.new(
            id: step_id,
            parent_id:,
            predecessor_ids:,
            branch_id:,
            participant:,
            assembly_id: child.class.respond_to?(:assembly_id) ? child.class.assembly_id : participant,
            assembly_kind: child.class.respond_to?(:assembly_kind) ? child.class.assembly_kind : :assembly,
            status: :completed,
            attempts:,
            usage:,
            output:,
            output_truncated: truncated
          )
          combined = copy_run_result(result, steps: [step, *nested_steps])
          events = attempt_events.map do |event|
            (event.type == :invocation_stop) ? StreamEvent.build(event.type, **event.data.merge(result: combined)) : event
          end
          transition = child.assembly_transition if child.respond_to?(:assembly_transition)
          return StepExecution.new(result: combined, step:, events: events.freeze, transition:)
        rescue => error
          if own_step_timeout?(error, deadline, child_deadline, policy[:timeout])
            error = AssemblyStepTimeoutError.new("assembly step #{participant.inspect} exceeded its timeout")
          end
          attempt_usage = error_usage(attempt_events, attempt_usage)
          usage += attempt_usage
          attempts << Attempt.new(
            number: attempt_number,
            status: :failed,
            started_at:,
            finished_at: Time.now,
            usage: attempt_usage,
            error: error.class.name
          )
          retrying = retry_step?(error, policy, index)
          annotate_step_error(error, step_id:, attempts:, usage:, child:, participant:)
          if block_given?
            yield StreamEvent.build(
              :assembly_step_error,
              step_id:,
              participant: participant.to_s,
              attempt: attempt_number,
              error_type: error.class.name,
              usage:,
              terminal: !retrying
            )
          end
          raise error unless retrying

          if block_given?
            yield StreamEvent.build(
              :assembly_step_retry,
              step_id:,
              participant: participant.to_s,
              attempt: attempt_number,
              error_type: error.class.name,
              delay: policy.fetch(:retry_delay)
            )
          end
          wait_for_retry(policy.fetch(:retry_delay), cancellation_token, deadline)
        ensure
          begin
            child.close
          rescue => cleanup_error
            cleanup_usage = usage
            annotate_step_error(
              cleanup_error,
              step_id:,
              attempts:,
              usage: cleanup_usage,
              child:,
              participant:
            )
            if block_given?
              yield StreamEvent.build(
                :assembly_step_error,
                step_id:,
                participant: participant.to_s,
                attempt: attempt_number,
                error_type: cleanup_error.class.name,
                usage: cleanup_usage,
                terminal: true
              )
            end
            raise
          end
        end
      end
    end

    def build_stream_participant(builder_name, reference, stream_path, **options)
      builder = runtime.method(builder_name)
      parameters = builder.parameters
      accepts_path = parameters.any? do |kind, name|
        kind == :keyrest || (%i[key keyreq].include?(kind) && name == :agent_stream_path)
      end
      options[:agent_stream_path] = stream_path if accepts_path
      child = builder.call(reference, run:, **options)
      child.bind_agent_stream_path(stream_path) if child.respond_to?(:bind_agent_stream_path)
      child
    end

    def normalize_step_policy(values)
      self.class.validate_step_policy!(values)
    end

    class << self
      def validate_step_policy!(values) # :nodoc:
        values = values.compact
        retries = Integer(values.fetch(:retries, 0))
        raise ArgumentError, "retries must be at least 0" if retries.negative?

        retry_on = Array(values[:retry_on])
        if retries.positive? && retry_on.empty?
          raise ArgumentError, "retry_on is required when retries is greater than 0"
        end
        unless retry_on.all? { |error| error.is_a?(Class) && error <= Exception }
          raise ArgumentError, "retry_on must contain exception classes"
        end
        timeout = Float(values[:timeout]) if values[:timeout]
        retry_delay = Float(values.fetch(:retry_delay, 0))
        raise ArgumentError, "timeout must be positive" if timeout && (!timeout.positive? || !timeout.finite?)
        raise ArgumentError, "retry_delay must be non-negative" if retry_delay.negative? || !retry_delay.finite?

        {retries:, retry_on: retry_on.freeze, timeout:, retry_delay:}.freeze
      end
    end

    def retry_step?(error, policy, index)
      return false if index >= policy.fetch(:retries)
      return false if error.is_a?(CancelledError) || error.is_a?(CleanupError)

      policy.fetch(:retry_on).any? { |type| error.is_a?(type) }
    end

    def step_deadline(parent_deadline, timeout)
      local = Time.now + timeout if timeout
      [parent_deadline, local].compact.min
    end

    def own_step_timeout?(error, parent_deadline, child_deadline, timeout)
      error.is_a?(DeadlineExceededError) && timeout && child_deadline && child_deadline != parent_deadline
    end

    def wait_for_retry(delay, cancellation_token, deadline)
      return if delay.zero?

      stop_at = Time.now + delay
      loop do
        cancellation_token.raise_if_cancelled!
        raise DeadlineExceededError, "The run deadline was reached" if deadline && Time.now >= deadline

        remaining = stop_at - Time.now
        break unless remaining.positive?

        cancellation_token.wait([remaining, 0.05].min)
      end
    end

    def error_usage(events, fallback)
      events.reverse_each do |event|
        return event.data[:usage] if event.type == :invocation_error && event.data[:usage]
      end
      fallback
    end

    def annotate_step_error(error, step_id:, attempts:, usage:, child:, participant:)
      error.instance_variable_set(:@little_ghost_step_id, step_id)
      error.instance_variable_set(:@little_ghost_step_attempts, attempts.dup.freeze)
      error.instance_variable_set(:@little_ghost_step_usage, usage)
      error.instance_variable_set(
        :@little_ghost_step_assembly_id,
        child.class.respond_to?(:assembly_id) ? child.class.assembly_id : participant.to_s
      )
      error.instance_variable_set(
        :@little_ghost_step_assembly_kind,
        child.class.respond_to?(:assembly_kind) ? child.class.assembly_kind : :assembly
      )
    end

    def projected_step_output(output)
      text = output.is_a?(String) ? output : JSON.generate(output)
      return [deep_frozen_assembly_value(output), false] if text.bytesize <= MAX_STEP_OUTPUT_BYTES

      [nil, true]
    rescue JSON::GeneratorError, TypeError
      [nil, true]
    end

    def reparent_steps(steps, parent_id)
      Array(steps).map do |step|
        next step if step.parent_id

        Step.new(**step.to_h.merge(parent_id:))
      end
    end

    def copy_run_result(result, usage: result.usage, steps: result.steps)
      RunResult.new(
        message: result.message,
        stop_reason: result.stop_reason,
        usage:,
        messages: result.messages,
        state: result.state,
        structured_result: result.structured_result,
        steps:
      )
    end

    def isolated_assembly_state(value)
      case value
      when Hash
        value.to_h { |key, item| [isolated_assembly_state(key), isolated_assembly_state(item)] }
      when Array
        value.map { |item| isolated_assembly_state(item) }
      when String
        value.dup
      when NilClass, TrueClass, FalseClass, Numeric, Symbol
        value
      else
        raise ArgumentError, "assembly context must contain only JSON-like state"
      end
    end

    def deep_frozen_assembly_value(value)
      copied = isolated_assembly_state(value)
      case copied
      when Hash
        copied.each do |key, item|
          deep_freeze_assembly_value(key)
          deep_freeze_assembly_value(item)
        end
      when Array
        copied.each { |item| deep_freeze_assembly_value(item) }
      end
      copied.freeze
    end

    def deep_freeze_assembly_value(value)
      case value
      when Hash
        value.each do |key, item|
          deep_freeze_assembly_value(key)
          deep_freeze_assembly_value(item)
        end
      when Array
        value.each { |item| deep_freeze_assembly_value(item) }
      end
      value.freeze
    end

    def buffer_assembly_event!(buffer, event, bytes:)
      raise AssemblyLimitError, "assembly step emitted too many events" if buffer.length >= MAX_STEP_EVENTS

      bytes += buffered_assembly_size(event)
      raise AssemblyLimitError, "assembly step emitted too much event data" if bytes > MAX_STEP_EVENT_BYTES

      buffer << event
      bytes
    end

    def buffered_assembly_size(value, ancestors = {}, depth = 0)
      return MAX_STEP_EVENT_BYTES + 1 if depth > 32

      identity = value.object_id
      return 0 if ancestors.key?(identity)

      case value
      when String
        value.bytesize
      when Hash
        ancestors[identity] = true
        value.sum do |key, item|
          buffered_assembly_size(key, ancestors, depth + 1) + buffered_assembly_size(item, ancestors, depth + 1)
        end
      when Array
        ancestors[identity] = true
        value.sum { |item| buffered_assembly_size(item, ancestors, depth + 1) }
      when Data
        ancestors[identity] = true
        value.members.sum { |member| buffered_assembly_size(value.public_send(member), ancestors, depth + 1) }
      else
        64
      end
    ensure
      ancestors.delete(identity) if identity
    end

    def enqueue_assembly_event(queue, value, cancellation_token)
      loop do
        cancellation_token.raise_if_cancelled!
        return if queue.push(value, timeout: 0.01)
      end
    end

    def enqueue_assembly_terminal(queue, value)
      queue.push(value, true)
    rescue ThreadError
      queue.pop(true)
      retry
    end
  end
end
