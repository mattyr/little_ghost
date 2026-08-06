# frozen_string_literal: true

module LittleGhost
  module Support
    module ClassAttributes
      def class_attribute(*names, default: nil)
        names.each do |name|
          unless name.is_a?(String) || name.is_a?(Symbol)
            raise TypeError, "#{name.inspect} is not a symbol nor a string"
          end

          name = name.to_sym
          define_singleton_method(name) { default }
          define_singleton_method("#{name}=") do |value|
            singleton_class.define_method(name) { value }
            value
          end
        end
      end
    end
  end
end
