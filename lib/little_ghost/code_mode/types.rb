# frozen_string_literal: true

module LittleGhost
  module CodeMode
    Call = Data.define(:id, :name, :arguments) # :nodoc:
    CallResult = Data.define(:id, :value, :error) # :nodoc:
    CellResult = Data.define(:output, :value, :status, :error, :continuation) do # :nodoc:
      def initialize(output: "", value: nil, status: :completed, error: nil, continuation: nil)
        super
      end

      def completed? = status == :completed
      def yielded? = status == :yielded
    end
  end
end
