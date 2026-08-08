# frozen_string_literal: true

module LittleGhost
  module Support
    module ClassAttributes
      def self.included(base)
        base.extend(self)
      end

      def class_attribute(*names, default: nil)
        names.each do |name|
          unless name.is_a?(String) || name.is_a?(Symbol)
            raise TypeError, "#{name.inspect} is not a symbol nor a string"
          end

          name = name.to_sym
          singleton_class.remove_method(name) if singleton_class.method_defined?(name, false)
          writer = :"#{name}="
          singleton_class.remove_method(writer) if singleton_class.method_defined?(writer, false)
          values = {self => default}
          mutex = Mutex.new
          define_singleton_method(name) do
            found, value = mutex.synchronize { [values.key?(self), values[self]] }
            return value if found

            superclass.public_send(name)
          end
          define_singleton_method(writer) do |value|
            mutex.synchronize { values[self] = value }
            value
          end
        end
      end
    end
  end
end
