# frozen_string_literal: true

module LittleGhost
  module CodeMode
    Call = Data.define(:id, :name, :arguments) # :nodoc:
    CallResult = Data.define(:id, :value, :error) # :nodoc:
    CellResult = Data.define(:output, :value, :status, :error) do # :nodoc:
      def initialize(output: "", value: nil, status: :completed, error: nil)
        super
      end

      def completed? = status == :completed
      def still_working? = status == :still_working
    end
  end
end
