defmodule Sesame.Cluster do
  @node_name :"sesame@sesame.local"
  @cookie <<"sesame">>
  @retry_interval 5_000

  def start_link do
    pid = spawn_link(__MODULE__, :init, [])
    :erlang.register(:cluster, pid)
    {:ok, pid}
  end

  def init do
    start_loop()
  end

  defp start_loop do
    :io.format(~c"[Cluster] attempting to start distribution...\n")

    case :epmd.start_link([]) do
      {:ok, _} -> :io.format(~c"[Cluster] EPMD started\n")
      {:error, {:already_started, _}} -> :ok
      err -> :io.format(~c"[Cluster] EPMD failed: ~p\n", [err])
    end

    case :net_kernel.start(@node_name, %{name_domain: :longnames}) do
      {:ok, _} ->
        :io.format(~c"[Cluster] net_kernel started as ~p\n", [@node_name])
        :net_kernel.set_cookie(@cookie)
        :io.format(~c"[Cluster] cookie set, node ready\n")
        idle_loop()

      err ->
        :io.format(~c"[Cluster] net_kernel failed: ~p, retrying in ~pms\n", [err, @retry_interval])

        :timer.sleep(@retry_interval)
        start_loop()
    end
  end

  defp idle_loop do
    :timer.sleep(60000)
    idle_loop()
  end
end
