# frozen_string_literal: true

module LittleGhost
  class Sandbox
    # A non-owning, capability-reduced view of a Sandbox for one agent or tool
    # set. Scopes never open or close their parent and cannot widen it.
    class Scope
      # Creates a view of +sandbox+. +mounts+ and +capabilities+ may only narrow
      # the parent scope or sandbox.
      def initialize(sandbox:, mounts: nil, capabilities: nil, network: nil, parent_scope: nil)
        @sandbox = sandbox
        @parent_mounts = parent_scope&.mounts || sandbox.effective_policy.effective_mounts(sandbox.workspace)
        @parent_tool_denies = if parent_scope
          parent_scope.send(:tool_deny_mounts)
        else
          @parent_mounts.reject(&:tool_visible?)
        end
        requested_mounts = mounts ? preserve_restrictive_overlays(normalize_mounts(mounts)) : @parent_mounts
        @mounts = validate_mounts(requested_mounts).sort_by { |mount| -mount.target.length }.freeze
        @tool_deny_mounts = relevant_tool_denies(@mounts).freeze
        parent_capabilities = parent_scope&.capabilities || sandbox.capabilities
        requested_capabilities = capabilities || parent_capabilities
        requested_capabilities = Capabilities.new(features: requested_capabilities) unless requested_capabilities.is_a?(Capabilities)
        @capabilities = parent_capabilities.intersect(requested_capabilities)
        @network = narrow_network(parent_scope&.network || sandbox.effective_policy.network, network)
        if @network
          unless parent_capabilities.supports?(:network, @network.mode)
            raise CapabilityError, "sandbox backend cannot enforce scoped network mode :#{@network.mode}"
          end
          @capabilities = @capabilities.intersect(Capabilities.new(
            features: @capabilities.features,
            network_modes: [@network.mode],
            isolation: @capabilities.isolation
          ))
        end
        @filesystem = Filesystem.new(
          mounts: (@mounts + @tool_deny_mounts).uniq,
          relative_root: sandbox.effective_policy.workspace_path,
          max_read_bytes: sandbox.limits.read_bytes,
          max_write_bytes: sandbox.limits.write_bytes,
          max_list_entries: sandbox.limits.list_entries
        )
        @mount_identities = mount_identities
      end

      # Sandbox that enforces process execution.
      attr_reader :sandbox
      # Virtual mounts visible through this scope.
      attr_reader :mounts
      # Operations exposed through this scope.
      attr_reader :capabilities
      # Outbound connectivity available to processes launched through this scope.
      attr_reader :network

      # Workspace owned by the parent sandbox.
      def workspace = sandbox.workspace
      # Effective policy enforced by the parent sandbox.
      def policy = sandbox.effective_policy
      # Effective policy enforced by the parent sandbox.
      alias_method :effective_policy, :policy

      # Indicates whether this scope exposes +feature+.
      def supports?(feature, value = nil) = capabilities.supports?(feature, value)
      # Indicates whether any visible mount accepts writes.
      def writable? = supports?(:filesystem_write) && mounts.any? { |mount| mount.tool_visible? && mount.writable? }

      # Indicates whether +operation+ is available at optional virtual +path+.
      def allows?(operation, path = nil)
        operation = Capabilities.normalize(operation)
        return supports?(operation) unless path

        @filesystem.allows?(operation, absolute_path(path))
      rescue PolicyError, ToolError
        false
      end

      # Reads bounded UTF-8 text through the scoped filesystem.
      def read(path, context: nil)
        require_capability!(:filesystem_read)
        @filesystem.read(path, context:)
      end

      # Lists one directory through the scoped filesystem.
      def list(path = ".", context: nil)
        require_capability!(:filesystem_list)
        @filesystem.list(path, context:)
      end

      # Writes bounded content through a writable scoped mount.
      def write(path, content, context: nil)
        require_capability!(:filesystem_write)
        @filesystem.write(path, content, context:)
      end

      # Replaces one unique text occurrence through a writable scoped mount.
      def replace(path, old_text, new_text, context: nil)
        require_capability!(:filesystem_replace)
        @filesystem.replace(path, old_text, new_text, context:)
      end

      # Executes a shell command through the parent sandbox and this scope.
      def execute(command, **options)
        require_capability!(:process_execute)
        sandbox.execute(command, scope: self, **options)
      end

      # Executes an argument vector through the parent sandbox and this scope.
      def execute_program(command, **options)
        require_capability!(:process_execute)
        sandbox.execute_program(command, scope: self, **options)
      end

      # Produces another view that can only narrow this scope.
      def scope(**options) = self.class.new(sandbox:, parent_scope: self, **options)
      # Scopes own no resources; opening returns the same object.
      def open(run: nil) = self
      # Scopes own no resources, so closing has no effect.
      def close = nil

      # Fails closed if a selected host mount was replaced after scope creation.
      def validate!
        current = mount_identities
        unless current == @mount_identities
          raise CapabilityError, "sandbox scope mount source changed after initialization"
        end

        self
      end

      private

      def normalize_mounts(values)
        Array(values).map do |value|
          if value.is_a?(Mount)
            value
          elsif value.is_a?(Hash)
            target = value[:target] || value["target"]
            access = value[:access] || value["access"] || :read_only
            parent_mount_for(target).narrow(target:, access:)
          else
            parent_mount_for(value).narrow(target: value)
          end
        end
      end

      def validate_mounts(values)
        values.map do |mount|
          parent = parent_mount_for(mount.target)
          narrowed = parent.narrow(target: mount.target, access: mount.access)
          unless File.realpath(mount.source) == File.realpath(narrowed.source)
            raise CapabilityError, "sandbox scope mount source must come from its parent"
          end
          narrowed
        rescue Errno::ENOENT, Errno::EACCES
          raise CapabilityError, "sandbox scope mount source is unavailable"
        end
      end

      def preserve_restrictive_overlays(values)
        overlays = @parent_mounts.select(&:read_only?).select do |restricted|
          values.any? do |selected|
            selected.writable? && (
              selected.covers?(restricted.target) ||
                protected_physical_alias?(restricted, selected)
            )
          end
        end
        (values + overlays).uniq
      end

      def relevant_tool_denies(values)
        @parent_tool_denies.select do |denied|
          values.any? do |selected|
            selected.covers?(denied.target) ||
              tool_deny_alias?(denied, selected)
          end
        end
      end

      attr_reader :tool_deny_mounts

      def tool_deny_alias?(denied, selected)
        denied_source = File.realpath(denied.source)
        selected_source = File.realpath(selected.source)
        denied_source == selected_source ||
          denied_source.start_with?("#{selected_source}#{File::SEPARATOR}")
      rescue Errno::ENOENT, Errno::EACCES
        raise CapabilityError, "sandbox scope mount source is unavailable"
      end

      def protected_physical_alias?(restricted, selected)
        return false unless restricted.protect_aliases? || !restricted.tool_visible?

        restricted_source = File.realpath(restricted.source)
        selected_source = File.realpath(selected.source)
        restricted_source == selected_source ||
          restricted_source.start_with?("#{selected_source}#{File::SEPARATOR}") ||
          selected_source.start_with?("#{restricted_source}#{File::SEPARATOR}")
      rescue Errno::ENOENT, Errno::EACCES
        raise CapabilityError, "sandbox scope mount source is unavailable"
      end

      def parent_mount_for(target)
        target = Mount.send(:normalize_virtual_path, target)
        @parent_mounts.find { |mount| mount.covers?(target) } ||
          raise(CapabilityError, "sandbox scope cannot expose a path outside its parent")
      end

      def absolute_path(path)
        value = String(path)
        value.start_with?(File::SEPARATOR) ? value : File.join(policy.workspace_path, value)
      end

      def require_capability!(feature)
        return if supports?(feature)

        raise ToolError, "Sandbox scope does not allow #{feature.to_s.tr("_", " ")}"
      end

      def mount_identities
        mounts.to_h do |mount|
          root = File.realpath(mount.source)
          stat = File.stat(root)
          [mount, [root, stat.dev, stat.ino]]
        end
      rescue Errno::ENOENT, Errno::EACCES
        raise CapabilityError, "sandbox scope mount source changed after initialization"
      end

      def narrow_network(parent, requested)
        return parent if requested.nil? || requested == true
        requested = NetworkPolicy.coerce(:none) if requested == false
        requested = NetworkPolicy.coerce(requested)
        return requested if parent&.inherit? && (requested.inherit? || requested.none?)
        return requested if parent&.allowlist? && requested.none?
        return parent if parent&.allowlist? && requested.allowlist? && requested == parent
        return parent if parent&.none? && requested.none?

        raise CapabilityError, "sandbox scope cannot widen network access"
      end
    end
  end
end
