defmodule Sesame.Heart do
  @delay 30_000

  def start_link do
    pid = spawn_link(__MODULE__, :init, [])
    {:ok, pid}
  end

  def init do
    :timer.sleep(@delay)
    Sesame.BootEnv.mark_valid()
    :io.format(~c"[Heart] OTA marked valid after ~p ms\n", [@delay])
  end
end
