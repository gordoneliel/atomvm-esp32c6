defmodule Ota do
  @moduledoc """
  A/B OTA update support for AtomVM.

  After a successful boot, call `Ota.mark_valid/0` to reset the boot counter.
  To update, call `Ota.write/1` with the new AVM binary, then `Ota.swap/0` to reboot into it.
  If the new AVM crashes 3 times without calling mark_valid, the bootloader rolls back.
  """

  def mark_valid do
    :ota_nif.mark_valid()
  end

  def write(binary) when is_binary(binary) do
    :ota_nif.write(binary)
  end

  def begin_ota(size) when is_integer(size) do
    :ota_nif.begin(size)
  end

  def write_chunk(offset, binary) when is_integer(offset) and is_binary(binary) do
    :ota_nif.write_chunk(offset, binary)
  end

  def swap do
    :ota_nif.swap()
  end
end
