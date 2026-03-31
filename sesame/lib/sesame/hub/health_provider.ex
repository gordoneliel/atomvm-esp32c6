defmodule Sesame.Hub.HealthProvider do
  @behaviour NervesHubLinkAVM.HealthProvider

  # 384KB SRAM + 8192KB PSRAM
  @total_kb 384 + 8192

  # Health check runs ~every 30s. Track CPU samples for load averages.
  # 1min = 2 samples, 5min = 10, 15min = 30
  @max_samples 30

  @impl true
  def health_check do
    free_heap = safe_system_info(:esp32_free_heap_size, 0)
    min_free = safe_system_info(:esp32_minimum_free_size, 0)
    largest_block = safe_system_info(:esp32_largest_free_block, 0)
    proc_count = safe_system_info(:process_count, 0)

    free_kb = div(free_heap, 1024)
    used_kb = @total_kb - free_kb
    used_kb = if used_kb < 0, do: 0, else: used_kb
    used_pct = div(used_kb * 100, @total_kb)

    cpu_pct =
      try do
        :sys_info_nif.cpu_percent()
      catch
        _, _ -> 0
      end

    # Track CPU samples in process dictionary for load averages
    samples = :erlang.get(:cpu_samples) || []
    samples = :lists.sublist([cpu_pct | samples], @max_samples)
    :erlang.put(:cpu_samples, samples)

    {load_1m, load_5m, load_15m} = compute_load_avgs(samples)

    :io.format(
      ~c"[Health] free=~pKB used=~pKB (~p%) procs=~p cpu=~p% load=~p/~p/~p\n",
      [free_kb, used_kb, used_pct, proc_count, cpu_pct, load_1m, load_5m, load_15m]
    )

    %{
      "mem_size_mb" => @total_kb / 1024,
      "mem_used_mb" => used_kb / 1024,
      "mem_used_percent" => used_pct,
      "cpu_usage_percent" => cpu_pct,
      "load_1min" => load_1m,
      "load_5min" => load_5m,
      "load_15min" => load_15m,
      "mem_total_kb" => @total_kb,
      "mem_used_kb" => used_kb,
      "free_heap_kb" => free_heap / 1024,
      "min_free_heap_kb" => min_free / 1024,
      "largest_free_block_kb" => largest_block / 1024,
      "process_count" => proc_count
    }
  end

  defp compute_load_avgs(samples) do
    load_1m = avg(:lists.sublist(samples, 2))
    load_5m = avg(:lists.sublist(samples, 10))
    load_15m = avg(samples)
    {load_1m, load_5m, load_15m}
  end

  defp avg([]), do: 0.0
  defp avg(list) do
    :lists.sum(list) / :erlang.length(list)
  end

  defp safe_system_info(key, default) do
    try do
      :erlang.system_info(key)
    catch
      _, _ -> default
    end
  end
end
