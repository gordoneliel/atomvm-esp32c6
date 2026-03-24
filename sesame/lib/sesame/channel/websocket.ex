defmodule Sesame.Channel.Websocket do
  @moduledoc """
  WebSocket client GenServer wrapping the websocket_nif.

  Usage:
    Sesame.Channel.Websocket.start_link("ws://host:port/path")
    Sesame.Channel.Websocket.send_text("hello")
    Sesame.Channel.Websocket.close()

  Events are forwarded to a registered handler process if set.
  """

  def start_link(url) do
    :gen_server.start_link({:local, :websocket}, __MODULE__, {url, []}, [])
  end

  def start_link(url, opts) do
    :gen_server.start_link({:local, :websocket}, __MODULE__, {url, opts}, [])
  end

  def send_text(data) do
    :websocket_nif.send_text(data)
  end

  def send_binary(data) do
    :websocket_nif.send_binary(data)
  end

  def close do
    :websocket_nif.close()
  end

  def is_connected do
    :websocket_nif.is_connected()
  end

  def set_handler(pid) do
    :gen_server.cast(:websocket, {:set_handler, pid})
  end

  def init({url, opts}) do
    headers = Keyword.get(opts, :headers, nil)

    result =
      if headers do
        :websocket_nif.connect(self(), url, headers)
      else
        :websocket_nif.connect(self(), url)
      end

    case result do
      :ok ->
        :io.format(~c"[WS] connecting to ~s\n", [url])
        {:ok, %{url: url, connected: false, handler: nil}}

      {:error, reason} ->
        :io.format(~c"[WS] connect failed: ~p\n", [reason])
        {:stop, reason}
    end
  end

  def handle_info(:ws_connected, state) do
    :io.format(~c"[WS] connected\n")
    notify_handler(state.handler, :ws_connected)
    {:noreply, %{state | connected: true}}
  end

  def handle_info({:ws_data, data}, state) do
    notify_handler(state.handler, {:ws_data, data})
    {:noreply, state}
  end

  def handle_info(:ws_disconnected, state) do
    :io.format(~c"[WS] disconnected\n")
    notify_handler(state.handler, :ws_disconnected)
    {:noreply, %{state | connected: false}}
  end

  def handle_info(:ws_error, state) do
    :io.format(~c"[WS] error\n")
    notify_handler(state.handler, :ws_error)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def handle_cast({:set_handler, pid}, state) do
    {:noreply, %{state | handler: pid}}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  defp notify_handler(nil, _msg), do: :ok
  defp notify_handler(pid, msg), do: send(pid, msg)
end
