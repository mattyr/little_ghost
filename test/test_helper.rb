# frozen_string_literal: true

require "minitest/autorun"
require "little_ghost"

class TestConfiguration < LittleGhost::Configuration
  class << self
    def runtime(root: nil, agent: nil)
      @test_runtime ||= begin
        settings = self.settings(root:)
        LittleGhost::Runtime.new(configuration: settings, agent: agent)
      end
    end

    def build(**overrides)
      return runtime.build(**overrides) if @test_runtime

      values = settings.merge(overrides)
      @test_runtime = LittleGhost::Runtime.new(configuration: values, agent: values[:agent])
    end
  end
end
