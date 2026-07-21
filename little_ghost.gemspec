# frozen_string_literal: true

require_relative "lib/little_ghost/version"

Gem::Specification.new do |spec|
  spec.name = "little_ghost"
  spec.version = LittleGhost::VERSION
  spec.authors = ["Matt Robinson"]
  spec.email = ["robinson.matty@gmail.com"]

  spec.summary = "A dependency-light agent framework for Ruby"
  spec.description = "A straightforward agent framework built for Ruby applications."
  spec.homepage = "https://github.com/mattyr/little_ghost"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/releases",
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage
  }

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "LICENSE.txt", "README.md"]
  end
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "standard", "~> 1.44"
end
