defmodule Sesame.Hub.HealthProvider do
  @behaviour NervesHubLinkAVM.HealthProvider

  # 384KB SRAM + 8MB PSRAM
  @total_kb 384 + 8192

  @impl true
  def health_check do
    free_heap = safe_system_info(:esp32_free_heap_size, 0)
    min_free = safe_system_info(:esp32_minimum_free_size, 0)
    largest_block = safe_system_info(:esp32_largest_free_block, 0)
    free_kb = div(free_heap, 1024)
    used_kb = @total_kb - free_kb
    used_pct = if @total_kb > 0, do: div(used_kb * 100, @total_kb), else: 0
    proc_count = safe_system_info(:process_count, 0)

    cpu_pct =
      try do
        result = :sys_info_nif.cpu_percent()
        result
      catch
        kind, err ->
          :io.format(~c"[Health] cpu_percent failed: ~p ~p\n", [kind, err])
          0
      end

    :io.format(
      ~c"[Health] free=~pKB min_free=~pKB largest=~pKB used=~pKB (~p%) procs=~p cpu=~p%\n",
      [
        free_kb,
        div(min_free, 1024),
        div(largest_block, 1024),
        used_kb,
        used_pct,
        proc_count,
        cpu_pct
      ]
    )

    %{
      "mem_size_mb" => @total_kb / 1024,
      "mem_used_mb" => used_kb / 1024,
      "mem_used_percent" => used_pct,
      "cpu_usage_percent" => cpu_pct,
      "mem_total_kb" => @total_kb,
      "mem_used_kb" => used_kb,
      "free_heap_bytes" => free_heap,
      "min_free_heap_bytes" => min_free,
      "largest_free_block" => largest_block,
      "process_count" => proc_count
    }
  end

  defp safe_system_info(key, default) do
    try do
      :erlang.system_info(key)
    catch
      _, _ -> default
    end
  end
end
