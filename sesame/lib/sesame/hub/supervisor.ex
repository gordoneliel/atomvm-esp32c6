defmodule Sesame.Hub.Supervisor do
  @hub_opts Application.compile_env!(:sesame, :nerveshub)

  def start_link do
    default_meta = Keyword.get(@hub_opts, :firmware_meta, %{})
    fw_meta = load_firmware_meta(default_meta)
    opts = Keyword.put(@hub_opts, :firmware_meta, fw_meta)

    :io.format(~c"[HubSup] firmware_meta: version=~s uuid=~s product=~s\n", [
      Map.get(fw_meta, "version", "?"),
      Map.get(fw_meta, "uuid", "?"),
      Map.get(fw_meta, "product", "?")
    ])

    logger_config = %{
      log_level: :info,
      logger: [
        {:handler, :default, :logger_std_h, %{}},
        {:handler, :nerveshub, NervesHubLinkAVM.LoggerHandler,
         %{config: %{server: NervesHubLinkAVM}}}
      ]
    }

    child_specs = [
      {NervesHubLinkAVM, {NervesHubLinkAVM, :start_link, [opts]}, :permanent, :brutal_kill,
       :worker, [NervesHubLinkAVM]},
      {:logger_manager, {:logger_manager, :start_link, [logger_config]}, :permanent,
       :brutal_kill, :worker, [:logger_manager]}
    ]

    :supervisor.start_link({:local, :hub_sup}, __MODULE__, child_specs)
  end

  def init(child_specs) do
    {:ok, {{:rest_for_one, 3, 30}, child_specs}}
  end

  defp load_firmware_meta(default_meta) do
    :maps.fold(fn key, default_value, acc ->
      value =
        try do
          case :esp.nvs_get_binary(:firmware_meta, key) do
            val when is_binary(val) and byte_size(val) > 0 -> val
            _ -> default_value
          end
        catch
          _, _ -> default_value
        end

      Map.put(acc, key, value)
    end, %{}, default_meta)
  end
end
