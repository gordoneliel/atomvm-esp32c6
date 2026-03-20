defmodule Sesame.Partition do
  def erase(size), do: :partition_nif.begin(size)
  def write_chunk(offset, chunk), do: :partition_nif.write_chunk(offset, chunk)
end
