defmodule Dist do
  def start_link do
    pid = spawn_link(__MODULE__, :init, [])
    :erlang.register(:dist, pid)
    {:ok, pid}
  end

  def init do
    receive do
      {:got_ip, {a, b, c, d}} ->
        :io.format(~c"[Dist] starting distribution...\n")

        case :epmd.start_link([]) do
          {:ok, _} -> :io.format(~c"[Dist] EPMD started\n")
          err -> :io.format(~c"[Dist] EPMD failed: ~p\n", [err])
        end

        node_name =
          :erlang.list_to_atom(
            :lists.flatten(:io_lib.format(~c"sesame@~B.~B.~B.~B", [a, b, c, d]))
          )

        :io.format(~c"[Dist] starting net_kernel as ~p\n", [node_name])

        case :net_kernel.start(node_name, %{name_domain: :longnames}) do
          {:ok, _} -> :io.format(~c"[Dist] net_kernel started\n")
          err -> :io.format(~c"[Dist] net_kernel failed: ~p\n", [err])
        end

        :io.format(~c"[Dist] about to set cookie\n")

        try do
          result = :net_kernel.set_cookie(<<"sesame">>)
          :io.format(~c"[Dist] set_cookie result: ~p\n", [result])
        catch
          kind, reason ->
            :io.format(~c"[Dist] set_cookie CRASHED: ~p ~p\n", [kind, reason])
        end

        try do
          cookie = :net_kernel.get_cookie()
          :io.format(~c"[Dist] current cookie: ~p\n", [cookie])
        catch
          kind, reason ->
            :io.format(~c"[Dist] get_cookie CRASHED: ~p ~p\n", [kind, reason])
        end

        :io.format(~c"[Dist] node started: ~p\n", [:erlang.node()])
    end

    idle_loop()
  end

  defp idle_loop do
    :timer.sleep(60000)
    idle_loop()
  end
end
