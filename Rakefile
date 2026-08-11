# frozen_string_literal: true

require "rake/testtask"
require "rdoc/task"

RDOC_TITLE = "LittleGhost Docs"
RDOC_MAIN = "README.md"
RDOC_FILES = ["README.md", "docs/guides/*.md", "lib/**/*.rb"].freeze
RDOC_OPTIONS = [
  "--encoding", "UTF-8",
  "--visibility", "public",
  "--template-stylesheets", "site/assets/docs.css",
  "--warn-missing-rdoc-ref"
].freeze
SITE_SOURCE = "site"
SITE_OUTPUT = "_site"

Rake::TestTask.new do |task|
  task.libs << "lib"
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

RDoc::Task.new do |rdoc|
  rdoc.title = RDOC_TITLE
  rdoc.main = RDOC_MAIN
  rdoc.rdoc_dir = "doc/rdoc"
  rdoc.rdoc_files.include(*RDOC_FILES)
  rdoc.options.concat(RDOC_OPTIONS)
end

namespace :site do
  desc "Build the GitHub Pages site and generated API documentation"
  task :build do
    rm_rf SITE_OUTPUT
    mkdir_p SITE_OUTPUT
    cp_r "#{SITE_SOURCE}/.", SITE_OUTPUT
    touch "#{SITE_OUTPUT}/.nojekyll"

    sh Gem.ruby, "-S", "rdoc",
      "--op", "#{SITE_OUTPUT}/docs",
      "--title", RDOC_TITLE,
      "--main", RDOC_MAIN,
      *RDOC_OPTIONS,
      *FileList[*RDOC_FILES].to_a
  end

  desc "Build and verify the complete GitHub Pages artifact"
  task check: :build do
    ruby "script/check_site.rb", SITE_OUTPUT
  end

  desc "Build and serve the site locally"
  task serve: :build do
    port = ENV.fetch("PORT", "4000")
    sh Gem.ruby, "script/serve_site.rb", SITE_OUTPUT, port
  end
end

task default: :test
