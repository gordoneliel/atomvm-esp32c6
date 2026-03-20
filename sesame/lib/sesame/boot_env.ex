defmodule Sesame.BootEnv do
  @moduledoc """
  A/B boot environment for AtomVM (similar to Nerves KV / U-Boot env).

  Manages boot slot selection, validity marking, and slot swapping.
  After a successful boot, call `mark_valid/0` to reset the boot counter.
  If the new firmware crashes 3 times without marking valid, the bootloader rolls back.
  """

  def mark_valid do
    :boot_env_nif.mark_valid()
  end

  def swap do
    :boot_env_nif.swap()
  end
end
