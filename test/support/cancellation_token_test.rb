# frozen_string_literal: true

require "test_helper"

class CancellationTokenTest < Minitest::Test
  def test_parent_cancellation_propagates_to_descendants
    parent = LittleGhost::Support::CancellationToken.new
    child = parent.child
    grandchild = child.child

    parent.cancel

    assert parent.cancelled?
    assert child.cancelled?
    assert grandchild.cancelled?
  end

  def test_child_cancellation_does_not_cancel_parent_or_siblings
    parent = LittleGhost::Support::CancellationToken.new
    child = parent.child
    sibling = parent.child

    child.cancel

    assert child.cancelled?
    refute parent.cancelled?
    refute sibling.cancelled?
  end

  def test_child_wait_wakes_when_parent_is_cancelled
    parent = LittleGhost::Support::CancellationToken.new
    child = parent.child
    waiting = Queue.new
    waiter = Thread.new { waiting << child.wait(30) }

    parent.cancel

    assert waiter.join(0.5), "child did not observe parent cancellation"
    assert waiting.pop
  ensure
    waiter&.kill
    waiter&.join
  end
end
