defmodule Firefly.Matter.Status do
  @moduledoc """
  What the matrix should show of the device's state, as a `Firefly.Lights`
  status (see `Firefly.Lights.set_status/1`):

    * `:commissioning` while not commissioned, waiting to be added to a home
    * none (`nil`) while commissioned and connected: Matter drives the light
    * `:offline` once commissioned but disconnected for `@offline_after_ms`,
      long enough to ride out reattaching after a restart or a brief drop

  Pure.
  """

  @offline_after_ms 10_000

  @type status :: :commissioning | :offline | nil

  @doc """
  Whether a Thread role and neighbor count (`:matter_nif.thread_status/0`)
  mean connected: attached to a network, with a parent or neighbors to talk
  to. A leader with no neighbors has made a network of its own.
  """
  def connected?({role, _neighbors}) when role in [:child, :router], do: true
  def connected?({:leader, neighbors}), do: neighbors > 0
  def connected?(_thread_status), do: false

  @doc """
  The status to show, and since when the connection has been down (`nil`
  while it's up), given whether the device is commissioned and connected,
  since when it was down before, and the time now, in milliseconds.
  """
  @spec status(boolean(), boolean(), integer() | nil, integer()) ::
          {status(), integer() | nil}
  def status(false = _commissioned, _connected, _down_since, _now), do: {:commissioning, nil}
  def status(true, true, _down_since, _now), do: {nil, nil}
  def status(true, false, nil, now), do: {nil, now}

  def status(true, false, down_since, now) when now - down_since >= @offline_after_ms,
    do: {:offline, down_since}

  def status(true, false, down_since, _now), do: {nil, down_since}
end
