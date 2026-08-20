# frozen_string_literal: true

module LittleGhost
  # Represents a file, image, or document produced by a Tool or supplied to a
  # Run. Inline artifacts contain their bytes. Deferred artifacts contain an
  # application-defined reference that the block passed to
  # Configuration#artifacts may use to load the bytes.
  #
  #   image = LittleGhost::Artifact.new(
  #     data: File.binread("chart.png"),
  #     media_type: "image/png",
  #     name: "chart.png"
  #   )
  #
  #   download = LittleGhost::Artifact.deferred(
  #     reference: {file_id: "file-481"},
  #     media_type: "application/pdf",
  #     name: "report.pdf"
  #   )
  class Artifact
    # Creates an inline artifact from binary +data+ and a MIME +media_type+.
    def initialize(data:, media_type:, name: nil, metadata: {})
      data = String(data).b
      initialize_fields(
        data: data.freeze,
        reference: nil,
        media_type:,
        name:,
        bytes: data.bytesize,
        metadata:
      )
    rescue TypeError
      raise ArgumentError, "artifact data must be a string"
    end

    # Creates an artifact whose bytes may be loaded later by the block passed to
    # Configuration#artifacts.
    def self.deferred(reference:, media_type:, name: nil, metadata: {})
      raise ArgumentError, "artifact reference is required" if reference.nil?
      reference = immutable_reference(reference)

      allocate.tap do |artifact|
        artifact.__send__(
          :initialize_fields,
          data: nil,
          reference:,
          media_type:,
          name:,
          bytes: nil,
          metadata:
        )
      end
    end

    # Binary content for an inline artifact, otherwise nil.
    attr_reader :data
    # Application-defined deferred reference, or generated Workspace reference
    # after storage; otherwise nil.
    attr_reader :reference
    # Optional display filename.
    attr_reader :name
    # MIME media type used to present the artifact.
    attr_reader :media_type
    # Known byte count, otherwise nil for an unresolved artifact.
    attr_reader :bytes
    # Deeply frozen application metadata.
    attr_reader :metadata

    # Whether this artifact contains its bytes directly.
    def inline? = !data.nil?

    # Whether this artifact requires an application resolver.
    def deferred? = !reference.nil? && bytes.nil?

    # Compares all immutable artifact fields.
    def ==(other)
      other.instance_of?(self.class) &&
        [data, reference, name, media_type, bytes, metadata] ==
          [other.data, other.reference, other.name, other.media_type, other.bytes, other.metadata]
    end
    # Uses the same field comparison when an artifact is a Hash key.
    alias_method :eql?, :==

    # Computes a Hash key from all immutable artifact fields.
    def hash = [self.class, data, reference, name, media_type, bytes, metadata].hash

    # Avoids placing bytes, names, metadata, or deferred references in diagnostics.
    def inspect
      kind = if inline?
        "inline"
      elsif deferred?
        "deferred"
      else
        "stored"
      end
      "#<#{self.class} kind=#{kind.inspect} media_type=#{media_type.inspect} bytes=#{bytes.inspect}>"
    end

    class << self
      def materialized(reference:, bytes:, media_type:, name: nil, metadata: {}) # :nodoc:
        reference = String(reference)
        bytes = Integer(bytes)
        raise ArgumentError, "artifact reference is required" if reference.empty?
        raise ArgumentError, "artifact bytes must not be negative" if bytes.negative?

        allocate.tap do |artifact|
          artifact.__send__(
            :initialize_fields,
            data: nil,
            reference: reference.freeze,
            media_type:,
            name:,
            bytes:,
            metadata:
          )
        end
      rescue TypeError
        raise ArgumentError, "materialized artifact fields are invalid"
      end

      private

      def immutable_reference(value)
        case value
        when String
          raise ArgumentError, "artifact reference is required" if value.empty?

          value.dup.freeze
        when Hash
          value.each_with_object({}) do |(key, child), copy|
            copy[immutable_reference(key)] = immutable_reference(child)
          end.freeze
        when Array
          value.map { |child| immutable_reference(child) }.freeze
        else
          unless value.frozen?
            raise ArgumentError, "artifact reference must be immutable"
          end

          value
        end
      end
    end

    private

    def initialize_fields(data:, reference:, media_type:, name:, bytes:, metadata:)
      media_type = String(media_type)
      raise ArgumentError, "artifact media_type is required" if media_type.empty?

      name = String(name) if name
      @data = data
      @reference = reference
      @name = name&.freeze
      @media_type = media_type.freeze
      @bytes = bytes
      @metadata = deep_freeze(DataMap.new(metadata))
      freeze
    rescue TypeError
      raise ArgumentError, "artifact fields are invalid"
    end

    def deep_freeze(value)
      pending = [value]
      until pending.empty?
        current = pending.pop
        case current
        when Hash
          current.each do |key, child|
            key.freeze
            pending << child
          end
        when Array
          current.each { |child| pending << child }
        end
        current.freeze
      end
      value
    end
  end
end
