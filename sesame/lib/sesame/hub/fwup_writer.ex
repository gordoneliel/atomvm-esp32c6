defmodule Sesame.Hub.FwupWriter do
  @behaviour NervesHubLinkAVM.FwupWriter

  # Partition mapping: .cap entry name → {slot_0_partition, slot_1_partition}
  @partition_map %{
    "app" => {"ota_0", "ota_1"},
    "avm" => {"main_a", "main_b"}
  }

  # --- FwupWriter callbacks ---

  @impl true
  def fwup_begin(_size, _meta) do
    {:ok, %{
      phase: :header,
      buffer: <<>>,
      entries: [],
      current_entry: 0,
      entry_offset: 0,
      sha256_ctx: nil,
      data_start: 0,
      active_slot: :boot_env_nif.active_slot()
    }}
  end

  @impl true
  def fwup_chunk(chunk, %{phase: :header} = state) do
    buffer = <<state.buffer::binary, chunk::binary>>

    case parse_header(buffer) do
      {:ok, entries, meta, data_start} ->
        :io.format(~c"[Capsule] header parsed: ~p entries\n", [length(entries)])
        save_firmware_meta(meta)
        inactive = if state.active_slot == 0, do: 1, else: 0

        # Erase all target partitions
        for entry <- entries do
          part = target_partition(entry.name, inactive)
          if part do
            :io.format(~c"[Capsule] erasing ~s for ~s (~p bytes)\n", [part, entry.name, entry.size])
            :partition_nif.erase(part, entry.size)
          end
        end

        # Start first entry
        first = hd(entries)
        :io.format(~c"[Capsule] writing ~s\n", [first.name])

        # Any leftover data after header goes to first entry
        leftover = binary_part(buffer, data_start, byte_size(buffer) - data_start)
        new_state = %{state |
          phase: :data,
          buffer: <<>>,
          entries: entries,
          current_entry: 0,
          entry_offset: 0,
          sha256_ctx: :crypto.hash_init(:sha256),
          data_start: data_start
        }

        if byte_size(leftover) > 0 do
          fwup_chunk(leftover, new_state)
        else
          {:ok, new_state}
        end

      :need_more ->
        {:ok, %{state | buffer: buffer}}
    end
  end

  def fwup_chunk(chunk, %{phase: :data} = state) do
    entry = Enum.at(state.entries, state.current_entry)
    remaining = entry.size - state.entry_offset
    inactive = if state.active_slot == 0, do: 1, else: 0

    {to_write, overflow} =
      if byte_size(chunk) <= remaining do
        {chunk, <<>>}
      else
        {binary_part(chunk, 0, remaining), binary_part(chunk, remaining, byte_size(chunk) - remaining)}
      end

    # Write to partition
    part = target_partition(entry.name, inactive)
    if part && byte_size(to_write) > 0 do
      :partition_nif.write(part, state.entry_offset, to_write)
    end

    # Update hash
    new_ctx = :crypto.hash_update(state.sha256_ctx, to_write)
    new_offset = state.entry_offset + byte_size(to_write)

    if new_offset >= entry.size do
      # Entry complete — verify SHA256
      computed = :crypto.hash_final(new_ctx)
      if computed != entry.sha256 do
        :io.format(~c"[Capsule] SHA256 MISMATCH for ~s!\n", [entry.name])
        {:error, :checksum_mismatch}
      else
        :io.format(~c"[Capsule] ~s verified OK\n", [entry.name])
        next_idx = state.current_entry + 1

        if next_idx < length(state.entries) do
          # Move to next entry
          next_entry = Enum.at(state.entries, next_idx)
          :io.format(~c"[Capsule] writing ~s\n", [next_entry.name])

          new_state = %{state |
            current_entry: next_idx,
            entry_offset: 0,
            sha256_ctx: :crypto.hash_init(:sha256)
          }

          if byte_size(overflow) > 0 do
            fwup_chunk(overflow, new_state)
          else
            {:ok, new_state}
          end
        else
          # All entries done
          {:ok, %{state | phase: :done}}
        end
      end
    else
      {:ok, %{state | entry_offset: new_offset, sha256_ctx: new_ctx}}
    end
  end

  @impl true
  def fwup_finish(%{phase: :done} = state) do
    inactive = if state.active_slot == 0, do: 1, else: 0
    :io.format(~c"[Capsule] activating slot ~p\n", [inactive])
    :boot_env_nif.activate(inactive)
    :io.format(~c"[Capsule] rebooting...\n")
    :esp.restart()
    :ok
  end

  def fwup_finish(_state) do
    :io.format(~c"[Capsule] finish called but not all entries written\n")
    {:error, :incomplete}
  end

  @impl true
  def fwup_abort(_state) do
    :io.format(~c"[Capsule] update aborted\n")
    :ok
  end

  @impl true
  def fwup_confirm do
    :boot_env_nif.mark_valid()
  end

  # --- .cap header parser ---

  defp parse_header(<<"CAP1", flags::16-big, header_len::32-big, count::16-big, rest::binary>>) do
    prefix_size = 4 + 2 + 4
    sig_size = if Bitwise.band(flags, 1) == 1, do: 64, else: 0
    total_header = prefix_size + header_len + sig_size

    if byte_size(rest) + prefix_size < total_header do
      :need_more
    else
      {entries, rest2} = parse_entries(rest, count, [])
      # Parse metadata (meta_len:16-big + meta_text)
      meta = case rest2 do
        <<meta_len::16-big, meta_text::binary-size(meta_len), _::binary>> -> parse_meta(meta_text)
        _ -> %{}
      end
      {:ok, entries, meta, total_header}
    end
  end

  defp parse_header(_), do: :need_more

  defp parse_entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp parse_entries(<<name_len::8, name::binary-size(name_len), size::32-big,
                       sha256::binary-size(32), rest::binary>>, count, acc) do
    entry = %{name: name, size: size, sha256: sha256}
    parse_entries(rest, count - 1, [entry | acc])
  end

  defp parse_meta(text) do
    lines = :binary.split(text, <<"\n">>, [:global])
    parse_meta_lines(lines, %{})
  end

  defp parse_meta_lines([], acc), do: acc
  defp parse_meta_lines([<<>> | rest], acc), do: parse_meta_lines(rest, acc)
  defp parse_meta_lines([line | rest], acc) do
    case :binary.split(line, <<"=">>) do
      [key, value] when key != <<>> ->
        parse_meta_lines(rest, Map.put(acc, key, value))
      _ ->
        parse_meta_lines(rest, acc)
    end
  end

  defp save_firmware_meta(meta) do
    :maps.fold(fn key, value, _ ->
      try do
        :esp.nvs_set_binary(:firmware_meta, key, value)
      catch
        _, _ -> :ok
      end
    end, :ok, meta)
    :io.format(~c"[Capsule] firmware metadata saved to NVS\n")
  end

  # --- Partition mapping ---

  defp target_partition(entry_name, inactive_slot) do
    case Map.get(@partition_map, entry_name) do
      {slot_0, slot_1} -> if inactive_slot == 1, do: slot_1, else: slot_0
      nil -> nil
    end
  end
end
