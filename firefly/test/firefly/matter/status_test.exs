defmodule Firefly.Matter.StatusTest do
  use ExUnit.Case, async: true

  alias Firefly.Matter.Status

  test "connected means attached with a parent or neighbors" do
    assert Status.connected?({:child, 1})
    assert Status.connected?({:router, 3})
    assert Status.connected?({:leader, 2})
    # A leader on its own has made a network of its own
    refute Status.connected?({:leader, 0})
    refute Status.connected?({:detached, 0})
    refute Status.connected?({:disabled, 0})
  end

  test "not commissioned shows commissioning" do
    assert Status.status(false, false, nil, 0) == {:commissioning, nil}
    assert Status.status(false, true, 500, 1000) == {:commissioning, nil}
  end

  test "commissioned and connected shows nothing" do
    assert Status.status(true, true, nil, 0) == {nil, nil}
    assert Status.status(true, true, 500, 99_000) == {nil, nil}
  end

  test "commissioned shows offline once disconnected for 10 s" do
    assert Status.status(true, false, nil, 1_000) == {nil, 1_000}
    assert Status.status(true, false, 1_000, 10_999) == {nil, 1_000}
    assert Status.status(true, false, 1_000, 11_000) == {:offline, 1_000}
    assert Status.status(true, false, 1_000, 60_000) == {:offline, 1_000}
  end
end
