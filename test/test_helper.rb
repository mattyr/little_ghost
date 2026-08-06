# frozen_string_literal: true

require "minitest/autorun"
require "little_ghost"

class TestConfiguration < LittleGhost::Configuration
  def runtime(root: nil, agent: nil)
    self.root(root) if root
    @test_runtime ||= LittleGhost::Runtime.new(configuration: self, entrypoint: agent)
  end

  def build(**overrides)
    return runtime.build(**overrides) if @test_runtime

    values = settings.merge(overrides)
    @test_runtime = LittleGhost::Runtime.new(configuration: self, entrypoint: values[:agent], settings: values)
  end
end
