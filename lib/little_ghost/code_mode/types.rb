# frozen_string_literal: true

module LittleGhost
  module CodeMode
    Call = Data.define(:id, :name, :arguments) # :nodoc:
    CallResult = Data.define(:id, :value, :error) # :nodoc:
    ProgramResult = Data.define(:output, :value, :status, :error) # :nodoc:

    # Describes one observation of a code-mode program. Its output contains text
    # produced since the previous observation.
    #
    # +value+ carries the completed program's language value when the engine
    # supports one. +status+ is +:completed+, +:still_working+, +:terminated+,
    # or +:error+. +error+ contains a model-program error; lifecycle and cleanup
    # failures raise instead.
    class ProgramResult < Data # :doc:
      ##
      # :attr_reader: error
      # A model-program error for an +:error+ result, or +nil+.

      ##
      # :attr_reader: output
      # Text produced since the previous observation.

      ##
      # :attr_reader: value
      # The completed program's language value, when available.

      ##
      # :attr_reader: status
      # The program state after this observation.

      # Creates a program observation with empty output and a successful status
      # by default.
      def initialize(output: "", value: nil, status: :completed, error: nil)
        super
      end

      # Whether the program completed successfully.
      def completed? = status == :completed

      # Whether the program remains active after this observation.
      def still_working? = status == :still_working
    end
  end
end
