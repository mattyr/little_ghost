# frozen_string_literal: true

# Loads LittleGhost's dependency-free filesystem and shell tool adapters.
# Requiring +little_ghost+ alone does not load these model-facing tools.
require_relative "tools/filesystem"
require_relative "tools/shell"
