# frozen_string_literal: true

module LittleGhost
  # A Workspace gives an agent a concrete home for files. Pair it with a Sandbox
  # to decide how those files may be read, changed, or used by commands.
  #
  #   workspace = LittleGhost::Workspace.new(root: "./tmp/support-run")
  #   workspace.root # => an absolute path ending in "/tmp/support-run"
  #
  # Workspaces participate in the run resource lifecycle. A custom workspace can
  # provision storage in #open and release it in #close.
  class Workspace
    # Expands +root+ to an absolute path.
    def initialize(root:)
      @root = File.expand_path(root)
    end

    # Absolute filesystem root assigned to this workspace.
    attr_reader :root

    # Opens any run-scoped resources and yields this workspace to the run.
    def open(run: nil)
      self
    end

    # Releases workspace resources. The default workspace has nothing to close.
    def close
      nil
    end
  end
end
