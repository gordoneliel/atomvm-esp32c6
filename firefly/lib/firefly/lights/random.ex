defmodule Firefly.Lights.Random do
  @moduledoc """
  A small pseudo-random number generator for animations.

  The generator's state is a seed the animation carries in its own state, so
  animations stay pure: the same seed always gives the same frames. Seed an
  animation from the `:seed` option, or `seed/0` when it isn't given:

      seed = Keyword.get_lazy(opts, :seed, &Random.seed/0)
      {col, seed} = Random.uniform(seed, Matrix.cols())
  """

  import Bitwise

  @mask 0x7FFFFFFF

  @doc "A fresh seed, from the ESP32's hardware random number generator."
  def seed do
    band(:atomvm.random(), @mask)
  catch
    # Not running on AtomVM (in tests on the host)
    :error, :undef -> band(:erlang.system_time(:microsecond), @mask)
  end

  @doc "A random integer in `0..(n - 1)` (for `n` up to 32768) and the next seed."
  def uniform(seed, n) do
    # A 31-bit linear congruential generator. Its low bits repeat quickly,
    # so the result comes from the high ones.
    seed = band(seed * 1_103_515_245 + 12345, @mask)
    {rem(bsr(seed, 16), n), seed}
  end

  @doc "True `percent`% of the time, and the next seed."
  def chance(seed, percent) do
    {roll, seed} = uniform(seed, 100)
    {roll < percent, seed}
  end
end
