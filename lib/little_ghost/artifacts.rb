# frozen_string_literal: true

module LittleGhost
  # Stores files from Run input and Tool results, then presents them to agents
  # as bounded images, documents, previews, or Workspace references.
  module Artifacts
  end
end

require_relative "artifacts/workspace_store"
require_relative "artifacts/presentation_budget"
