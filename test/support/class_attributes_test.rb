# frozen_string_literal: true

require "test_helper"

class ClassAttributesTest < Minitest::Test
  def test_subclasses_inherit_until_they_assign_their_own_value
    base = Class.new do
      extend LittleGhost::Support::ClassAttributes

      class_attribute :setting, default: "base"
    end
    child = Class.new(base)

    assert_equal "base", child.setting

    child.setting = "child"
    base.setting = "updated"

    assert_equal "child", child.setting
    assert_equal "updated", base.setting
  end
end
