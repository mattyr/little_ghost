# frozen_string_literal: true

require_relative "lib/little_ghost/version"

Gem::Specification.new do |spec|
  spec.name = "little_ghost"
  spec.version = LittleGhost::VERSION
  spec.authors = ["Matt Robinson"]
  spec.email = ["robinson.matty@gmail.com"]

  spec.summary = "A Ruby framework for AI features with agents and composable assemblies"
  spec.description = "Add agents, tools, workflows, swarms, and graphs to existing Ruby systems or dedicated AI services."
  spec.homepage = "https://github.com/mattyr/little_ghost"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/releases",
    "documentation_uri" => "https://mattyr.github.io/little_ghost/docs/",
    "source_code_uri" => spec.homepage,
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "lib/**/*.json", "docs/guides/*.md", "LICENSE.txt", "README.md"]
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "base64"
  spec.add_dependency "fiddle"
  spec.add_dependency "json_schemer", "~> 2.5"
  spec.add_dependency "opentelemetry-api", "~> 1.0"

  spec.add_development_dependency "async", "~> 2.39"
  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "mini_racer", "~> 0.21"
  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "rdoc", "~> 8.0"
  spec.add_development_dependency "standard", "~> 1.44"
  spec.add_development_dependency "webrick", "~> 1.9"
end
