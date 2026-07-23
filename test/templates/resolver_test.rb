# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "little_ghost/templates/resolver"

class TemplatesResolverTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("little-ghost-templates")
    @invocation = File.join(@directory, "invocation")
    @application = File.join(@directory, "application")
    @gem = File.join(@directory, "gem")
    [@invocation, @application, @gem].each { |path| FileUtils.mkdir_p(path) }
    @resolver = LittleGhost::Templates::Resolver.new(
      application_paths: [@application],
      gem_paths: [@gem]
    )
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_uses_invocation_then_application_then_gem_precedence
    write(@gem, "system.erb", "gem")
    write(@application, "system.erb", "application")

    assert_equal "application", @resolver.render("system")

    write(@invocation, "system.erb", "invocation")
    trusted = LittleGhost::Templates::TrustedPath.new(path: @invocation)
    assert_equal "invocation", @resolver.render("system", invocation_paths: [trusted])
  end

  def test_rejects_untrusted_invocation_template_paths
    assert_raises(ArgumentError) do
      @resolver.render("system", invocation_paths: [@invocation])
    end
  end

  def test_renders_explicit_locals_and_partials_relative_to_parent
    write(@application, "agents/system.erb", "Hello <%= name %>! <%= partial \"detail\", locals: {value: 42} %>")
    write(@application, "agents/_detail.erb", "Value: <%= value %>")

    result = @resolver.render("agents/system", locals: {name: "Ghost"})

    assert_equal "Hello Ghost! Value: 42", result
  end

  def test_partial_does_not_implicitly_inherit_parent_locals
    write(@application, "system.erb", "<%= partial \"detail\" %>")
    write(@application, "_detail.erb", "<%= secret %>")

    error = assert_raises(LittleGhost::Templates::MissingLocalError) do
      @resolver.render("system", locals: {secret: "hidden"})
    end
    assert_includes error.message, "secret"
  end

  def test_reports_a_missing_local
    write(@application, "system.erb", "Hello <%= name %>")

    error = assert_raises(LittleGhost::Templates::MissingLocalError) do
      @resolver.render("system")
    end

    assert_equal "Missing template local: name", error.message
  end

  def test_rejects_traversal_absolute_paths_and_symlink_escapes
    write(@directory, "secret.erb", "secret")
    File.symlink(File.join(@directory, "secret.erb"), File.join(@application, "linked.erb"))

    assert_raises(LittleGhost::Templates::InvalidTemplateError) { @resolver.render("../secret") }
    assert_raises(LittleGhost::Templates::InvalidTemplateError) { @resolver.render(File.join(@directory, "secret")) }
    assert_raises(LittleGhost::Templates::MissingTemplateError) { @resolver.render("linked") }
  end

  def test_detects_partial_cycles_and_depth_limits
    write(@application, "loop.erb", "<%= partial \"recursive\" %>")
    write(@application, "_recursive.erb", "<%= partial \"recursive\" %>")

    assert_raises(LittleGhost::Templates::InvalidTemplateError) { @resolver.render("loop") }

    shallow = LittleGhost::Templates::Resolver.new(application_paths: [@application], max_depth: 1)
    write(@application, "one.erb", "<%= partial \"two\" %>")
    write(@application, "_two.erb", "done")
    assert_raises(LittleGhost::Templates::InvalidTemplateError) { shallow.render("one") }
  end

  def test_invalidates_the_compiled_template_cache_when_file_changes
    path = write(@application, "system.erb", "first")
    assert_equal "first", @resolver.render("system")

    File.write(path, "second version")
    assert_equal "second version", @resolver.render("system")
  end

  def test_renders_safely_from_multiple_threads
    write(@application, "system.erb", "Hello <%= name %>")

    results = 10.times.map do |index|
      Thread.new { @resolver.render("system", locals: {name: index}) }
    end.map(&:value)

    assert_equal((0...10).map { |index| "Hello #{index}" }, results)
  end

  private

  def write(root, name, content)
    path = File.join(root, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end
end
