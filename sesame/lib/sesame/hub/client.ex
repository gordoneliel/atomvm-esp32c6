defmodule Sesame.Hub.Client do
  @behaviour NervesHubLinkAVM.Client

  @impl true
  def reboot do
    :io.format(~c"[Hub] reboot requested\n")
    :esp.restart()
    :ok
  end

  @impl true
  def identify do
    :io.format(~c"[Hub] identify requested\n")
    :ok
  end

  @impl true
  def handle_connected do
    :io.format(~c"[Hub] connected to NervesHub\n")
    :ok
  end

  @impl true
  def handle_disconnected do
    :io.format(~c"[Hub] disconnected from NervesHub\n")
    :ok
  end
end
