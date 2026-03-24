defmodule Sesame.Channel.Phoenix do
  @moduledoc """
  Minimal Phoenix channel client over WebSocket.

  Usage:
    Sesame.Channel.Phoenix.start_link(url, "room:lobby", self())
    Sesame.Channel.Phoenix.push("new_msg", [{:body, "hello"}])

  The handler process receives:
    {:channel_joined, response}
    {:channel_event, event, payload}
    {:channel_error, reason}
  """

  @heartbeat_interval 30_000

  def start_link(url, topic, handler_pid) do
    start_link(url, topic, handler_pid, [])
  end

  def start_link(url, topic, handler_pid, opts) do
    :gen_server.start_link({:local, :phoenix_channel}, __MODULE__, {url, topic, handler_pid, opts}, [])
  end

  def push(event, payload) do
    :gen_server.cast(:phoenix_channel, {:push, event, payload})
  end

  def init({url, topic, handler_pid, opts}) do
    ws_url = append_vsn(url)
    headers = Keyword.get(opts, :headers, nil)

    result =
      if headers do
        :websocket_nif.connect(self(), ws_url, headers)
      else
        :websocket_nif.connect(self(), ws_url)
      end

    case result do
      :ok ->
        :io.format(~c"[Phoenix] connecting to ~s\n", [ws_url])

        {:ok,
         %{
           topic: topic,
           handler: handler_pid,
           join_ref: "1",
           ref: 1,
           joined: false,
           heartbeat_ref: nil
         }}

      {:error, reason} ->
        :io.format(~c"[Phoenix] connect failed: ~p\n", [reason])
        {:stop, reason}
    end
  end

  def handle_info(:ws_connected, state) do
    :io.format(~c"[Phoenix] WS connected, joining ~s\n", [state.topic])
    join_msg = encode_msg(state.join_ref, next_ref(state), state.topic, "phx_join", "{}")
    :websocket_nif.send_text(join_msg)
    schedule_heartbeat()
    {:noreply, %{state | ref: state.ref + 1}}
  end

  def handle_info({:ws_data, data}, state) do
    case decode_msg(data) do
      {_join_ref, _ref, _topic, "phx_reply", payload} ->
        status = get_nested(payload, :status)

        if status == "ok" do
          :io.format(~c"[Phoenix] joined ~s\n", [state.topic])
          response = get_nested(payload, :response)
          notify(state.handler, {:channel_joined, response})
          {:noreply, %{state | joined: true}}
        else
          :io.format(~c"[Phoenix] join failed: ~p\n", [payload])
          notify(state.handler, {:channel_error, :join_failed})
          {:noreply, state}
        end

      {_join_ref, _ref, "phoenix", "phx_reply", _payload} ->
        {:noreply, state}

      {_join_ref, _ref, topic, event, payload} when topic == state.topic ->
        notify(state.handler, {:channel_event, event, payload})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:heartbeat, state) do
    if :websocket_nif.is_connected() == true do
      msg = encode_msg("null", next_ref(state), "phoenix", "heartbeat", "{}")
      :websocket_nif.send_text(msg)
      schedule_heartbeat()
      {:noreply, %{state | ref: state.ref + 1}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:ws_disconnected, state) do
    :io.format(~c"[Phoenix] disconnected\n")
    notify(state.handler, {:channel_error, :disconnected})
    {:noreply, %{state | joined: false}}
  end

  def handle_info(:ws_error, state) do
    :io.format(~c"[Phoenix] WS error\n")
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def handle_cast({:push, event, payload}, state) do
    if state.joined do
      payload_json = :erlang.iolist_to_binary(:json_encoder.encode(payload))
      msg = encode_msg(state.join_ref, next_ref(state), state.topic, event, payload_json)
      :websocket_nif.send_text(msg)
      {:noreply, %{state | ref: state.ref + 1}}
    else
      :io.format(~c"[Phoenix] not joined, dropping push\n")
      {:noreply, state}
    end
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  defp append_vsn(url) do
    sep =
      case :binary.match(url, <<"?">>) do
        :nomatch -> "?"
        _ -> "&"
      end

    <<url::binary, sep::binary, "vsn=2.0.0">>
  end

  defp next_ref(state) do
    :erlang.integer_to_binary(state.ref)
  end

  defp encode_msg(join_ref, ref, topic, event, payload_json) do
    jr = encode_value(join_ref)
    r = encode_value(ref)
    t = encode_value(topic)
    e = encode_value(event)
    <<"[", jr::binary, ",", r::binary, ",", t::binary, ",", e::binary, ",", payload_json::binary, "]">>
  end

  defp encode_value("null"), do: <<"null">>
  defp encode_value(nil), do: <<"null">>
  defp encode_value(v) when is_binary(v), do: <<"\"", v::binary, "\"">>
  defp encode_value(v) when is_integer(v), do: :erlang.integer_to_binary(v)

  defp decode_msg(data) do
    case Sesame.JsonDecoder.decode(data) do
      [join_ref, ref, topic, event, payload] ->
        {join_ref, ref, topic, event, payload}

      _ ->
        :error
    end
  end

  defp get_nested(proplist, key) when is_list(proplist) do
    :proplists.get_value(key, proplist, nil)
  end

  defp get_nested(_, _), do: nil

  defp schedule_heartbeat do
    :erlang.send_after(@heartbeat_interval, self(), :heartbeat)
  end

  defp notify(nil, _msg), do: :ok
  defp notify(pid, msg), do: send(pid, msg)
end
