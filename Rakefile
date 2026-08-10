# frozen_string_literal: true

require "rake/testtask"
require "rdoc/task"

Rake::TestTask.new do |task|
  task.libs << "lib"
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

RDoc::Task.new do |rdoc|
  rdoc.title = "LittleGhost API Documentation"
  rdoc.main = "README.md"
  rdoc.rdoc_dir = "doc/rdoc"
  rdoc.rdoc_files.include("README.md", "docs/guides/*.md", "lib/**/*.rb")
  rdoc.options << "--encoding" << "UTF-8"
  rdoc.options << "--visibility" << "public"
  rdoc.options << "--warn-missing-rdoc-ref"
end

task default: :test
