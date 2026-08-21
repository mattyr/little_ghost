# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class ArtifactsTest < Minitest::Test
  def test_inline_and_deferred_artifacts_are_immutable_and_redacted
    metadata = {"nested" => {"items" => ["value"]}}
    inline = LittleGhost::Artifact.new(
      data: "secret bytes",
      media_type: "text/plain",
      name: "report.txt",
      metadata:
    )
    deferred = LittleGhost::Artifact.deferred(
      reference: "secret:record:1",
      media_type: "application/octet-stream"
    )
    metadata["nested"]["items"] << "changed"

    assert inline.inline?
    assert_equal 12, inline.bytes
    assert_equal ["value"], inline.metadata.dig("nested", "items")
    assert_raises(FrozenError) { inline.metadata.dig("nested", "items") << "changed" }
    assert deferred.deferred?
    refute_includes inline.inspect, "secret bytes"
    refute_includes inline.inspect, "report.txt"
    refute_includes inline.inspect, "nested"
    refute_includes inline.inspect, "value"
    refute_includes deferred.inspect, "secret:record:1"
  end

  def test_deferred_artifacts_accept_frozen_opaque_references
    reference_class = Data.define(:token, :callback)
    reference = reference_class.new(token: "signed-token", callback: -> { "bytes" })

    artifact = LittleGhost::Artifact.deferred(
      reference:,
      media_type: "application/octet-stream"
    )

    assert_same reference, artifact.reference
    refute_includes artifact.inspect, "signed-token"
    assert_raises(ArgumentError) do
      LittleGhost::Artifact.deferred(reference: Object.new, media_type: "text/plain")
    end
  end

  def test_workspace_store_materializes_deduplicates_and_bounds_artifacts
    with_workspace do |workspace|
      store = LittleGhost::Artifacts::WorkspaceStore.new(
        workspace:,
        max_artifact_bytes: 4,
        max_total_bytes: 6,
        max_artifacts: 2
      )
      first = store.write(data: "one", media_type: "text/plain", name: "one.txt")
      duplicate = store.write(data: "one", media_type: "text/plain", name: "one.txt")

      assert_same first, duplicate
      assert_match(%r{\Aworkspace://artifacts/}, first.reference)
      assert_equal "one", File.binread(workspace.resolve(first.reference))
      assert_equal 3, store.total_bytes
      assert_equal 1, store.size
      assert_raises(LittleGhost::ToolError) do
        store.write(data: "toolarge", media_type: "text/plain")
      end
      assert_raises(LittleGhost::ToolError) do
        store.write(data: "four", media_type: "text/plain")
      end
    end
  end

  def test_workspace_stores_use_private_unique_files_in_a_reused_directory
    with_workspace do |workspace|
      first_store = LittleGhost::Artifacts::WorkspaceStore.new(workspace:)
      second_store = LittleGhost::Artifacts::WorkspaceStore.new(workspace:)

      first = first_store.write(data: "same", media_type: "text/plain", name: "report.txt")
      second = second_store.write(data: "same", media_type: "text/plain", name: "report.txt")
      first_path = workspace.resolve(first.reference)
      second_path = workspace.resolve(second.reference)

      refute_equal first.reference, second.reference
      assert_equal "same", File.binread(first_path)
      assert_equal "same", File.binread(second_path)
      assert_equal 0o600, File.stat(first_path).mode & 0o777
      assert_equal 0o600, File.stat(second_path).mode & 0o777
    end
  end

  def test_workspace_store_preserves_distinct_metadata_for_identical_bytes
    with_workspace do |workspace|
      store = LittleGhost::Artifacts::WorkspaceStore.new(workspace:)

      first = store.write(
        data: "same",
        media_type: "text/plain",
        name: "report.txt",
        metadata: {source: "first"}
      )
      second = store.write(
        data: "same",
        media_type: "text/plain",
        name: "report.txt",
        metadata: {source: "second"}
      )

      refute_same first, second
      refute_equal first.reference, second.reference
      assert_equal "first", first.metadata.fetch("source")
      assert_equal "second", second.metadata.fetch("source")
      assert_equal 2, store.size
    end
  end

  def test_workspace_store_accepts_a_workspace_reached_through_a_symlinked_parent
    Dir.mktmpdir do |physical_parent|
      Dir.mktmpdir do |logical_parent|
        File.symlink(physical_parent, File.join(logical_parent, "redirect"))
        workspace = LittleGhost::Workspace.new(
          root: File.join(logical_parent, "redirect", "run"),
          paths: {artifacts: "artifacts"}
        ).open

        artifact = LittleGhost::Artifacts::WorkspaceStore.new(workspace:).write(
          data: "safe",
          media_type: "text/plain"
        )

        assert_equal "safe", File.binread(workspace.resolve(artifact.reference))
      ensure
        workspace&.close
      end
    end
  end

  def test_workspace_store_reports_a_missing_named_path_as_unavailable
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:).open

      error = assert_raises(LittleGhost::ToolError) do
        LittleGhost::Artifacts::WorkspaceStore.new(workspace:)
      end

      assert_equal "Artifact workspace path is unavailable", error.message
    ensure
      workspace&.close
    end
  end

  def test_workspace_store_rolls_back_a_failed_batch
    with_workspace do |workspace|
      store = LittleGhost::Artifacts::WorkspaceStore.new(
        workspace:,
        max_artifact_bytes: 3,
        max_total_bytes: 4,
        max_artifacts: 2
      )

      assert_raises(LittleGhost::ToolError) do
        store.write_batch([
          {data: "one", media_type: "text/plain"},
          {data: "two", media_type: "text/plain"}
        ])
      end

      assert_empty Dir.children(workspace.path(:artifacts))
      assert_equal 0, store.total_bytes
      assert_equal 0, store.size
      assert store.write(data: "one", media_type: "text/plain")
    end
  end

  def test_workspace_store_rolls_back_a_batch_cancelled_after_its_first_write
    with_workspace do |workspace|
      store = LittleGhost::Artifacts::WorkspaceStore.new(workspace:)
      token = LittleGhost::Support::CancellationToken.new
      control_class = Data.define(:token) do
        def check! = token.raise_if_cancelled!

        def artifact_control_values
          {cancellation_tokens: [token], deadlines: []}
        end
      end
      control = control_class.new(token:)
      original_materialize = store.method(:materialize)
      store.define_singleton_method(:materialize) do |**arguments|
        artifact = original_materialize.call(**arguments)
        token.cancel
        artifact
      end

      assert_raises(LittleGhost::CancelledError) do
        store.write_batch([
          {data: "one", media_type: "text/plain"},
          {data: "two", media_type: "text/plain"}
        ], context: control)
      end

      assert_empty Dir.children(workspace.path(:artifacts))
      assert_equal 0, store.total_bytes
      assert_equal 0, store.size
    end
  end

  def test_presentation_budget_keeps_references_without_unbounded_media
    budget = LittleGhost::Artifacts::PresentationBudget.new
    image = LittleGhost::Content::Image.new(data: "x", media_type: "image/png")

    accepted = Array.new(LittleGhost::Artifacts::PresentationBudget::MAX_COUNT) do
      budget.accept([image])
    end

    assert accepted.all? { |content| content == [image] }
    assert_empty budget.accept([image])
  end

  def test_presentation_budget_is_shared_safely_by_parallel_results
    budget = LittleGhost::Artifacts::PresentationBudget.new
    image = LittleGhost::Content::Image.new(data: "x", media_type: "image/png")

    accepted = Array.new(100) { Thread.new { budget.accept([image]) } }.map(&:value)

    assert_equal LittleGhost::Artifacts::PresentationBudget::MAX_COUNT,
      accepted.count { |content| content == [image] }
    assert_equal 100 - LittleGhost::Artifacts::PresentationBudget::MAX_COUNT,
      accepted.count(&:empty?)
  end

  def test_presentation_budget_rejects_media_over_eight_mebibytes
    budget = LittleGhost::Artifacts::PresentationBudget.new
    document = LittleGhost::Content::Document.new(
      data: "x" * (LittleGhost::Artifacts::PresentationBudget::MAX_BYTES + 1),
      media_type: "application/octet-stream",
      name: "large.bin"
    )

    assert_empty budget.accept([document])
  end

  def test_artifact_hook_stages_input_attachments_atomically
    hook = LittleGhost::Runtime::Hooks::Artifacts.configured.new
    image = LittleGhost::Content::Image.new(data: "image", media_type: "image/png", name: "chart.png")

    with_run(message: LittleGhost::Message.new(role: :user, content: ["Review", image])) do |run|
      hook.prepare_execution(run)

      message = run.invocation.message
      descriptor = message.metadata.fetch("little_ghost_artifacts").fetch(0)
      assert_equal [LittleGhost::Content::Text.new(text: "Review"), image], message.content
      refute_includes message.text, descriptor.fetch("reference")
      assert_equal "image", File.binread(run.workspace.resolve(descriptor.fetch("reference")))
    end
  end

  def test_deferred_resolver_can_supply_a_final_media_type
    deferred = LittleGhost::Artifact.deferred(
      reference: "record:1",
      media_type: "application/octet-stream"
    )
    seen = nil
    hook = LittleGhost::Runtime::Hooks::Artifacts.configured(
      resolver: lambda do |artifact, run:|
        seen = [artifact, run]
        LittleGhost::Artifact.new(data: "png", media_type: "image/png", name: "chart.png")
      end
    ).new
    result = LittleGhost::Tool::ExecutionResult.new(
      value: {"ok" => true},
      status: :success,
      artifacts: [deferred]
    )
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "chart", input: {})

    with_run do |run|
      prepared = hook.prepare_tool_result(
        result,
        tool_use:,
        run:,
        workspace: run.workspace,
        context: run.context
      )

      assert_equal [deferred, run], seen
      assert_equal "image/png", prepared.artifacts.first.media_type
      assert_equal "png", prepared.presentation_content.first.data
      assert_equal({"ok" => true}, prepared.content)
      refute_includes prepared.content.to_s, prepared.artifacts.first.reference
    end
  end

  def test_cancelled_results_do_not_invoke_deferred_resolvers
    called = false
    hook = LittleGhost::Runtime::Hooks::Artifacts.configured(
      resolver: lambda do |_artifact, run:|
        called = true
        LittleGhost::Artifact.new(data: "bytes", media_type: "text/plain")
      end
    ).new
    result = LittleGhost::Tool::ExecutionResult.new(
      value: "complete",
      status: :success,
      artifacts: [LittleGhost::Artifact.deferred(reference: "record:1", media_type: "text/plain")]
    )
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "export", input: {})
    context = LittleGhost::RunContext.new(
      cancellation_token: LittleGhost::Support::CancellationToken.new.cancel
    )

    with_run do |run|
      assert_raises(LittleGhost::CancelledError) do
        hook.prepare_tool_result(result, tool_use:, run:, workspace: run.workspace, context:)
      end
    end
    refute called
  end

  def test_explicit_non_image_artifacts_are_presented_as_documents
    artifact = LittleGhost::Artifact.new(
      data: "heading,value\nalpha,1\n",
      media_type: "text/csv",
      name: "report.csv"
    )
    unnamed = LittleGhost::Artifact.new(
      data: "binary",
      media_type: "application/octet-stream"
    )
    result = LittleGhost::Tool::ExecutionResult.new(
      value: {"rows" => 1},
      status: :success,
      artifacts: [artifact, unnamed]
    )
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "export", input: {})
    hook = LittleGhost::Runtime::Hooks::Artifacts.configured.new

    with_run do |run|
      prepared = hook.prepare_tool_result(
        result,
        tool_use:,
        run:,
        workspace: run.workspace,
        context: run.context
      )

      document = prepared.presentation_content.fetch(0)
      assert_instance_of LittleGhost::Content::Document, document
      assert_equal "text/csv", document.media_type
      assert_equal "report.csv", document.name
      assert_equal artifact.data, document.data
      assert_equal "artifact", prepared.presentation_content.fetch(1).name
      prepared.artifacts.each { |stored| refute_includes prepared.content.to_s, stored.reference }
    end
  end

  def test_unresolved_deferred_references_are_not_exposed_to_the_model
    reference_class = Data.define(:token)
    artifact = LittleGhost::Artifact.deferred(
      reference: reference_class.new(token: "opaque-secret"),
      media_type: "application/octet-stream"
    )
    result = LittleGhost::Tool::ExecutionResult.new(
      value: "complete",
      status: :success,
      artifacts: [artifact]
    )
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "export", input: {})
    hook = LittleGhost::Runtime::Hooks::Artifacts.configured.new

    with_run do |run|
      prepared = hook.prepare_tool_result(
        result,
        tool_use:,
        run:,
        workspace: run.workspace,
        context: run.context
      )

      assert_equal [artifact], prepared.artifacts
      assert_equal "complete", prepared.content
      refute_includes prepared.content, "opaque-secret"
    end
  end

  def test_oversized_values_are_offloaded_without_changing_machine_value
    value = {"data" => "x" * 50_000}
    result = LittleGhost::Tool::ExecutionResult.new(value:, status: :success)
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "report", input: {})
    hook = LittleGhost::Runtime::Hooks::Artifacts.configured.new

    with_run do |run|
      prepared = hook.prepare_tool_result(
        result,
        tool_use:,
        run:,
        workspace: run.workspace,
        context: run.context
      )

      assert_same value, prepared.value
      artifact = prepared.artifacts.fetch(0)
      assert_equal "application/json", artifact.media_type
      assert_match(/\.json\z/, artifact.name)
      assert_equal value, JSON.parse(File.binread(run.workspace.resolve(artifact.reference)))
      assert_includes prepared.content, "Full result:"
      assert_operator prepared.content.length, :<, JSON.generate(value).length
      assert_empty prepared.presentation_content
    end
  end

  def test_automatic_storage_falls_back_when_no_workspace_is_available
    value = "x" * 50_000
    result = LittleGhost::Tool::ExecutionResult.new(value:, status: :success)
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "report", input: {})
    hook = LittleGhost::Runtime::Hooks::Artifacts.configured.new

    prepared = hook.prepare_tool_result(
      result,
      tool_use:,
      run: nil,
      workspace: nil,
      context: LittleGhost::RunContext.new
    )

    assert_same value, prepared.value
    assert_empty prepared.artifacts
    assert_includes prepared.content, "Full result exceeded artifact storage limits"
    assert_operator prepared.content.length, :<, value.length
  end

  def test_automatic_storage_does_not_swallow_lifecycle_control_errors
    value = Object.new
    value.define_singleton_method(:to_s) { raise LittleGhost::CancelledError, "cancelled" }
    result = LittleGhost::Tool::ExecutionResult.new(
      value:,
      content: "x" * 50_000,
      status: :success
    )
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "report", input: {})
    hook = LittleGhost::Runtime::Hooks::Artifacts.configured.new

    assert_raises(LittleGhost::CancelledError) do
      hook.prepare_tool_result(
        result,
        tool_use:,
        run: nil,
        workspace: nil,
        context: LittleGhost::RunContext.new
      )
    end
  end

  def test_automatic_storage_accepts_results_between_sixteen_and_thirty_two_mebibytes
    value = "x" * (17 * 1024 * 1024)
    result = LittleGhost::Tool::ExecutionResult.new(value:, status: :success)
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "report", input: {})
    hook = LittleGhost::Runtime::Hooks::Artifacts.configured.new

    with_run do |run|
      prepared = hook.prepare_tool_result(
        result,
        tool_use:,
        run:,
        workspace: run.workspace,
        context: run.context
      )

      assert_same value, prepared.value
      artifact = prepared.artifacts.fetch(0)
      assert_equal value.bytesize, artifact.bytes
      assert_equal value.bytesize, File.size(run.workspace.resolve(artifact.reference))
      assert_operator prepared.content.length, :<, value.length
    end
  end

  def test_automatic_storage_failure_does_not_discard_explicit_artifacts
    value = "x" * (LittleGhost::Artifacts::WorkspaceStore::DEFAULT_MAX_ARTIFACT_BYTES + 1)
    explicit = LittleGhost::Artifact.new(data: "ok", media_type: "text/plain", name: "note.txt")
    result = LittleGhost::Tool::ExecutionResult.new(value:, status: :success, artifacts: [explicit])
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "report", input: {})
    hook = LittleGhost::Runtime::Hooks::Artifacts.configured.new

    with_run do |run|
      prepared = hook.prepare_tool_result(
        result,
        tool_use:,
        run:,
        workspace: run.workspace,
        context: run.context
      )

      assert_same value, prepared.value
      assert_equal 1, prepared.artifacts.length
      assert_equal "ok", File.binread(run.workspace.resolve(prepared.artifacts.first.reference))
      assert_equal "ok", prepared.presentation_content.first.data
      assert_includes prepared.content, "Full result exceeded artifact storage limits"
      assert_operator prepared.content.length, :<, value.length
    end
  end

  def test_explicit_artifact_reports_a_controlled_error_without_a_workspace
    result = LittleGhost::Tool::ExecutionResult.new(
      value: "complete",
      status: :success,
      artifacts: [LittleGhost::Artifact.new(data: "bytes", media_type: "text/plain")]
    )
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "export", input: {})
    hook = LittleGhost::Runtime::Hooks::Artifacts.configured.new

    error = assert_raises(LittleGhost::ToolError) do
      hook.prepare_tool_result(
        result,
        tool_use:,
        run: nil,
        workspace: nil,
        context: LittleGhost::RunContext.new
      )
    end

    assert_equal "Tool artifacts could not be prepared (LittleGhost::ToolError)", error.message
  end

  def test_configuration_artifacts_uses_one_run_shared_store
    configuration = LittleGhost::Configuration.new
    hook_class = configuration.artifacts
    runtime = LittleGhost::Runtime.new(
      configuration:,
      settings: configuration.settings.merge(
        root: Dir.pwd,
        workspace: nil,
        sandbox: nil,
        model_resolver: configuration.model_resolver,
        default_model: "default"
      )
    )

    assert_operator hook_class, :<, LittleGhost::Runtime::Hooks::Artifacts
    assert_equal 1, runtime.runtime_hooks.count { |hook| hook.is_a?(LittleGhost::Runtime::Hooks::Artifacts) }
    assert_equal File.join(Dir.pwd, "artifacts"), runtime.build_workspace.path(:artifacts)
  end

  def test_artifact_hooks_share_one_store_for_a_run
    first_hook = LittleGhost::Runtime::Hooks::Artifacts.configured.new
    second_hook = LittleGhost::Runtime::Hooks::Artifacts.configured.new

    with_run do |run|
      first = first_hook.send(:store_for, run, run.workspace)
      second = second_hook.send(:store_for, run, run.workspace)

      assert_same first, second
    end
  end

  private

  def with_workspace
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:, paths: {artifacts: "artifacts"}).open
      yield workspace
    ensure
      workspace&.close
    end
  end

  def with_run(message: "start")
    with_workspace do |workspace|
      run = LittleGhost::Run.new(
        invocation: LittleGhost::Invocation.new(message:),
        runtime: TestRuntime.new,
        entrypoint_class: LittleGhost::Agent,
        workspace:
      )
      yield run
    ensure
      run&.close
    end
  end
end
