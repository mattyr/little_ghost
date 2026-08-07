# frozen_string_literal: true

module LittleGhost
  class Workspace
    def initialize(root:)
      @root = File.expand_path(root)
    end

    attr_reader :root

    def open(run: nil)
      self
    end

    def close
      nil
    end
  end
end
