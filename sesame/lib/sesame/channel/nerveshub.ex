defmodule Sesame.Channel.NervesHub do
  @moduledoc """
  NervesHub device channel client using shared secret authentication.

  Connects to NervesHub via Phoenix channel, joins the "device" topic,
  and handles firmware update events.

  The handler process receives:
    {:nerveshub_joined, response}
    {:nerveshub_update, %{firmware_url: url, firmware_meta: meta}}
    {:nerveshub_error, reason}
  """

  @heartbeat_interval 30_000
  @reconnect_delay 5_000
  @device_api_version "2.3.0"
  @extensions_topic "extensions"

  @default_config %{
    host: "REDACTED_HOST",
    product_key: "REDACTED_PRODUCT_KEY",
    product_secret: "REDACTED_PRODUCT_SECRET",
    device_identifier: "SESAME-00000000",
    firmware_version: "0.0.0-alpha-0",
    firmware_uuid: "bff0a78f-d669-47dd-85c4-8ed2d1eeb752",
    product: "WorkplaceOS",
    platform: "Sesame",
    architecture: "riscv32"
  }

  def start_link do
    start_link(%{})
  end

  def start_link(config) do
    merged = Map.merge(@default_config, config)
    :gen_server.start_link({:local, :nerveshub}, __MODULE__, merged, [])
  end

  def init(config) do
    host = Map.get(config, :host, "devices.nerveshub.org")
    product_key = Map.fetch!(config, :product_key)
    product_secret = Map.fetch!(config, :product_secret)
    device_id = Map.fetch!(config, :device_identifier)
    handler = Map.get(config, :handler, nil)

    headers = build_auth_headers(product_key, product_secret, device_id)

    ws_url = <<"wss://", host::binary, "/device-socket/websocket?vsn=2.0.0">>

    result = :websocket_nif.connect(self(), ws_url, headers)

    case result do
      :ok ->
        :io.format(~c"[NervesHub] connecting to ~s\n", [host])

        {:ok,
         %{
           config: config,
           host: host,
           device_id: device_id,
           handler: handler,
           join_ref: "1",
           ext_join_ref: "2",
           ref: 1,
           joined: false,
           ext_joined: false,
           heartbeat_ref: nil,
           shell_buf: <<>>
         }}

      {:error, reason} ->
        :io.format(~c"[NervesHub] connect failed: ~p\n", [reason])
        {:stop, reason}
    end
  end

  def handle_info(:ws_connected, state) do
    :io.format(~c"[NervesHub] WS connected, joining device channel\n")

    join_payload = build_join_payload(state.config)
    msg = encode_msg(state.join_ref, next_ref(state), "device", "phx_join", join_payload)
    :websocket_nif.send_text(msg)
    schedule_heartbeat()
    {:noreply, %{state | ref: state.ref + 1}}
  end

  def handle_info({:ws_data, data}, state) do
    case decode_msg(data) do
      {_jr, _ref, "device", "phx_reply", payload} ->
        status = get_nested(payload, :status)

        if status == "ok" do
          :io.format(~c"[NervesHub] joined device channel\n")
          response = get_nested(payload, :response)
          notify(state.handler, {:nerveshub_joined, response})
          {:noreply, %{state | joined: true}}
        else
          :io.format(~c"[NervesHub] join failed: ~p\n", [payload])
          notify(state.handler, {:nerveshub_error, :join_failed})
          {:noreply, state}
        end

      {_jr, _ref, "device", "extensions:get", _payload} ->
        # Server asks what extensions we support — respond by joining extensions topic
        :io.format(~c"[NervesHub] extensions:get, joining extensions topic\n")
        ext_payload = <<"{\"health\":\"0.0.1\",\"local_shell\":\"0.0.1\"}">>

        ext_msg =
          encode_msg(
            state.ext_join_ref,
            next_ref(state),
            @extensions_topic,
            "phx_join",
            ext_payload
          )

        :websocket_nif.send_text(ext_msg)
        {:noreply, %{state | ref: state.ref + 1}}

      {_jr, _ref, @extensions_topic, "phx_reply", payload} ->
        status = get_nested(payload, :status)

        if status == "ok" and not state.ext_joined do
          :io.format(~c"[NervesHub] joined extensions channel\n")
          # Server reply contains which extensions to attach
          response = get_nested(payload, :response)
          :io.format(~c"[NervesHub] extensions response: ~p\n", [response])
          # Attach extensions
          health_msg = encode_msg(state.ext_join_ref, next_ref(state), @extensions_topic, "health:attached", "{}")
          :websocket_nif.send_text(health_msg)
          shell_msg = encode_msg(state.ext_join_ref, int_to_bin(state.ref + 1), @extensions_topic, "local_shell:attached", "{}")
          :websocket_nif.send_text(shell_msg)
          :io.format(~c"[NervesHub] extensions attached (health, local_shell)\n")
          {:noreply, %{state | ext_joined: true, ref: state.ref + 2}}
        else
          {:noreply, state}
        end

      {_jr, _ref, @extensions_topic, "attach", payload} ->
        :io.format(~c"[NervesHub] extensions attach requested: ~p\n", [payload])

        attach_msg =
          encode_msg(
            state.ext_join_ref,
            next_ref(state),
            @extensions_topic,
            "health:attached",
            "{}"
          )

        :websocket_nif.send_text(attach_msg)
        {:noreply, %{state | ref: state.ref + 1}}

      {_jr, _ref, @extensions_topic, "health:check", _payload} ->
        :io.format(~c"[NervesHub] health check requested\n")
        send_health_report(state)

      {_jr, _ref, @extensions_topic, "local_shell:request_shell", _payload} ->
        :io.format(~c"[Shell] session requested\n")
        push_ext(state, "local_shell:request_status", <<"{\"status\":\"started\"}">>)
        push_ext(state, "local_shell:shell_output", <<"{\"data\":\"AtomVM Shell on ESP32-C6\\r\\nType :mod.fun(args) to call functions\\r\\n\\r\\natvm> \"}">>)
        {:noreply, %{state | ref: state.ref + 2}}

      {_jr, _ref, @extensions_topic, "local_shell:shell_input", payload} ->
        input = get_nested(payload, :data)
        if input do
          handle_shell_input(input, state)
        else
          {:noreply, state}
        end

      {_jr, _ref, @extensions_topic, "local_shell:kill_shell", _payload} ->
        :io.format(~c"[Shell] session killed\n")
        push_ext(state, "local_shell:shell_exited", <<"{\"exit_code\":0}">>)
        {:noreply, %{state | ref: state.ref + 1}}

      {_jr, _ref, @extensions_topic, "local_shell:window_size", _payload} ->
        {:noreply, state}

      {_jr, _ref, "phoenix", "phx_reply", _payload} ->
        {:noreply, state}

      {_jr, _ref, "device", "update", payload} ->
        :io.format(~c"[NervesHub] firmware update available\n")
        handle_update(payload, state)

      {_jr, _ref, "device", "reboot", _payload} ->
        :io.format(~c"[NervesHub] reboot requested\n")
        push_event(state, "rebooting", "{}")
        :esp.restart()
        {:noreply, state}

      {_jr, _ref, "device", "identify", _payload} ->
        :io.format(~c"[NervesHub] identify requested\n")
        {:noreply, state}

      {_jr, _ref, "device", event, payload} ->
        :io.format(~c"[NervesHub] event: ~s\n", [event])
        notify(state.handler, {:nerveshub_event, event, payload})
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
    :io.format(~c"[NervesHub] disconnected, will reconnect in ~pms\n", [@reconnect_delay])
    :websocket_nif.close()
    notify(state.handler, {:nerveshub_error, :disconnected})
    :erlang.send_after(@reconnect_delay, self(), :reconnect)
    {:noreply, %{state | joined: false, ext_joined: false}}
  end

  def handle_info(:ws_error, state) do
    :io.format(~c"[NervesHub] WS error\n")
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    :io.format(~c"[NervesHub] reconnecting with fresh auth...\n")
    config = state.config
    product_key = Map.fetch!(config, :product_key)
    product_secret = Map.fetch!(config, :product_secret)
    device_id = Map.fetch!(config, :device_identifier)
    host = state.host

    headers = build_auth_headers(product_key, product_secret, device_id)
    ws_url = <<"wss://", host::binary, "/device-socket/websocket?vsn=2.0.0">>

    case :websocket_nif.connect(self(), ws_url, headers) do
      :ok ->
        :io.format(~c"[NervesHub] reconnecting to ~s\n", [host])
        {:noreply, %{state | joined: false, ext_joined: false, ref: 1, shell_buf: <<>>}}

      {:error, reason} ->
        :io.format(~c"[NervesHub] reconnect failed: ~p, retrying...\n", [reason])
        :erlang.send_after(@reconnect_delay, self(), :reconnect)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  # --- Shell ---

  defp handle_shell_input(data, state) do
    handle_shell_chars(data, state)
  end

  defp handle_shell_chars(<<>>, state), do: {:noreply, state}

  defp handle_shell_chars(<<"\r", rest::binary>>, state) do
    # Enter pressed — echo newline, evaluate buffer, show prompt
    buf = state.shell_buf
    output = if byte_size(buf) > 0 do
      Sesame.Channel.LocalShell.eval(buf)
    else
      <<>>
    end
    # Send: \r\n + output + prompt
    shell_send_raw(state, <<"\r\n", output::binary, "atvm> ">>)
    handle_shell_chars(rest, %{state | shell_buf: <<>>, ref: state.ref + 1})
  end

  defp handle_shell_chars(<<"\n", rest::binary>>, state) do
    handle_shell_chars(<<"\r", rest::binary>>, state)
  end

  # Backspace (0x7F) or ctrl-H (0x08)
  defp handle_shell_chars(<<127, rest::binary>>, state) do
    handle_shell_backspace(rest, state)
  end

  defp handle_shell_chars(<<8, rest::binary>>, state) do
    handle_shell_backspace(rest, state)
  end

  # Ctrl-C
  defp handle_shell_chars(<<3, rest::binary>>, state) do
    shell_send_raw(state, <<"\r\n^C\r\natvm> ">>)
    handle_shell_chars(rest, %{state | shell_buf: <<>>, ref: state.ref + 1})
  end

  # Ctrl-U — clear line
  defp handle_shell_chars(<<21, rest::binary>>, state) do
    buf_len = byte_size(state.shell_buf)
    if buf_len > 0 do
      clear = :binary.copy(<<8, 32, 8>>, buf_len)
      shell_send_raw(state, clear)
    end
    handle_shell_chars(rest, %{state | shell_buf: <<>>, ref: state.ref + 1})
  end

  # Skip escape sequences and other control characters
  defp handle_shell_chars(<<27, rest::binary>>, state) do
    # ESC — skip escape sequence (arrow keys etc)
    skip_escape_seq(rest, state)
  end

  defp handle_shell_chars(<<c, rest::binary>>, state) when c < 32 do
    handle_shell_chars(rest, state)
  end

  # Regular printable character — echo and buffer
  defp handle_shell_chars(<<c, rest::binary>>, state) do
    shell_send_raw(state, <<c>>)
    new_buf = <<state.shell_buf::binary, c>>
    handle_shell_chars(rest, %{state | shell_buf: new_buf, ref: state.ref + 1})
  end

  defp handle_shell_backspace(rest, state) do
    if byte_size(state.shell_buf) > 0 do
      new_buf = binary_part(state.shell_buf, 0, byte_size(state.shell_buf) - 1)
      shell_send_raw(state, <<8, 32, 8>>)
      handle_shell_chars(rest, %{state | shell_buf: new_buf, ref: state.ref + 1})
    else
      handle_shell_chars(rest, state)
    end
  end

  defp skip_escape_seq(<<"[", _c, rest::binary>>, state), do: handle_shell_chars(rest, state)
  defp skip_escape_seq(<<_c, rest::binary>>, state), do: handle_shell_chars(rest, state)
  defp skip_escape_seq(<<>>, state), do: {:noreply, state}

  defp shell_send_raw(state, data) do
    escaped = json_escape(data)
    push_ext(state, "local_shell:shell_output", <<"{\"data\":\"", escaped::binary, "\"}">>)
  end

  # --- Extensions helpers ---

  defp push_ext(state, event, payload) do
    msg = encode_msg(state.ext_join_ref, next_ref(state), @extensions_topic, event, payload)
    :websocket_nif.send_text(msg)
  end

  defp json_escape(str) do
    json_escape(str, <<>>)
  end

  defp json_escape(<<>>, acc), do: acc
  defp json_escape(<<"\"", rest::binary>>, acc), do: json_escape(rest, <<acc::binary, "\\\"">>)
  defp json_escape(<<"\\", rest::binary>>, acc), do: json_escape(rest, <<acc::binary, "\\\\">>)
  defp json_escape(<<"\n", rest::binary>>, acc), do: json_escape(rest, <<acc::binary, "\\n">>)
  defp json_escape(<<"\r", rest::binary>>, acc), do: json_escape(rest, <<acc::binary, "\\r">>)
  defp json_escape(<<"\t", rest::binary>>, acc), do: json_escape(rest, <<acc::binary, "\\t">>)
  defp json_escape(<<c, rest::binary>>, acc) when c < 0x20, do: json_escape(rest, acc)
  defp json_escape(<<c, rest::binary>>, acc), do: json_escape(rest, <<acc::binary, c>>)

  # --- Health ---

  defp send_health_report(state) do
    report = build_health_report()
    payload = <<"{\"value\":", report::binary, "}">>

    msg =
      encode_msg(state.ext_join_ref, next_ref(state), @extensions_topic, "health:report", payload)

    :websocket_nif.send_text(msg)
    :io.format(~c"[NervesHub] health report sent\n")
    {:noreply, %{state | ref: state.ref + 1}}
  end

  defp build_health_report do
    timestamp = iso8601_now()
    free_heap = safe_system_info(:esp32_free_heap_size, 0)
    total_kb = 512
    free_kb = div(free_heap, 1024)
    used_kb = total_kb - free_kb
    used_pct = if total_kb > 0, do: div(used_kb * 100, total_kb), else: 0
    proc_count = safe_system_info(:process_count, 0)

    cpu_pct =
      try do
        result = :sys_info_nif.cpu_percent()
        :io.format(~c"[Health] cpu_percent NIF returned: ~p\n", [result])
        result
      catch
        kind, err ->
          :io.format(~c"[Health] cpu_percent NIF failed: ~p ~p\n", [kind, err])
          0
      end

    :io.format(~c"[Health] free=~pKB used=~pKB (~p%) cpu=~p% procs=~p\n",
      [free_kb, used_kb, used_pct, cpu_pct, proc_count])

    <<"{",
      "\"timestamp\":\"", timestamp::binary, "\",",
      "\"metadata\":{},",
      "\"alarms\":{},",
      "\"metrics\":{",
        "\"mem_size_mb\":1,",
        "\"mem_used_mb\":1,",
        "\"mem_used_percent\":", int_to_bin(used_pct)::binary, ",",
        "\"cpu_usage_percent\":", int_to_bin(cpu_pct)::binary, ",",
        "\"mem_total_kb\":", int_to_bin(total_kb)::binary, ",",
        "\"mem_used_kb\":", int_to_bin(used_kb)::binary, ",",
        "\"free_heap_bytes\":", int_to_bin(free_heap)::binary, ",",
        "\"process_count\":", int_to_bin(proc_count)::binary,
      "},",
      "\"checks\":{},",
      "\"connectivity\":{}",
    "}">>
  end

  defp safe_system_info(key, default) do
    try do
      :erlang.system_info(key)
    catch
      _, _ -> default
    end
  end

  defp iso8601_now do
    {{y, mo, d}, {h, mi, s}} = :erlang.universaltime()

    pad2 = fn n ->
      b = int_to_bin(n)
      if n < 10, do: <<"0", b::binary>>, else: b
    end

    pad4 = fn n -> int_to_bin(n) end

    <<pad4.(y)::binary, "-", pad2.(mo)::binary, "-", pad2.(d)::binary, "T", pad2.(h)::binary, ":",
      pad2.(mi)::binary, ":", pad2.(s)::binary, "Z">>
  end

  defp int_to_bin(n), do: :erlang.integer_to_binary(n)

  # --- Auth ---

  defp build_auth_headers(product_key, product_secret, device_id) do
    alg = "NH1-HMAC-sha256-1000-32"
    time_val = unix_time()
    time = :erlang.integer_to_binary(time_val)

    salt =
      <<"NH1:device-socket:shared-secret:connect\n\nx-nh-alg=", alg::binary, "\nx-nh-key=",
        product_key::binary, "\nx-nh-time=", time::binary, "\n">>

    signature =
      Sesame.Channel.PlugCrypto.sign(product_secret, salt, device_id,
        key_iterations: 1000,
        key_length: 32,
        signed_at: time_val
      )

    <<"x-nh-alg: ", alg::binary, "\r\nx-nh-key: ", product_key::binary, "\r\nx-nh-time: ",
      time::binary, "\r\nx-nh-signature: ", signature::binary, "\r\n">>
  end

  # --- Join payload ---

  defp build_join_payload(config) do
    version = Map.get(config, :firmware_version, "0.0.0")
    uuid = Map.get(config, :firmware_uuid, "unknown")
    product = Map.get(config, :product, "sesame")
    platform = Map.get(config, :platform, "esp32c6")
    architecture = Map.get(config, :architecture, "riscv32")

    fields = [
      kv("nerves_fw_version", version),
      kv("nerves_fw_uuid", uuid),
      kv("nerves_fw_product", product),
      kv("nerves_fw_platform", platform),
      kv("nerves_fw_architecture", architecture),
      kv("device_api_version", @device_api_version)
    ]

    <<"{", :erlang.iolist_to_binary(join_fields(fields))::binary, "}">>
  end

  defp kv(key, value), do: {key, value}

  defp join_fields([]), do: []
  defp join_fields([{k, v}]), do: [<<"\"", k::binary, "\":\"", v::binary, "\"">>]

  defp join_fields([{k, v} | rest]) do
    [<<"\"", k::binary, "\":\"", v::binary, "\",">> | join_fields(rest)]
  end

  # --- Update handling ---

  defp handle_update(payload, state) do
    firmware_url = get_nested(payload, :firmware_url)

    if firmware_url do
      :io.format(~c"[NervesHub] firmware URL: ~s\n", [firmware_url])
      notify(state.handler, {:nerveshub_update, payload})

      push_event(state, "status_update", encode_status("received"))
    end

    {:noreply, state}
  end

  defp encode_status(status) do
    <<"{\"status\":\"", status::binary, "\"}">>
  end

  defp push_event(state, event, payload_json) do
    if state.joined do
      msg = encode_msg(state.join_ref, next_ref(state), "device", event, payload_json)
      :websocket_nif.send_text(msg)
    end
  end

  # --- Message encoding/decoding ---

  defp encode_msg(join_ref, ref, topic, event, payload_json) do
    jr = encode_value(join_ref)
    r = encode_value(ref)
    t = encode_value(topic)
    e = encode_value(event)

    <<"[", jr::binary, ",", r::binary, ",", t::binary, ",", e::binary, ",", payload_json::binary,
      "]">>
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

  defp next_ref(state), do: :erlang.integer_to_binary(state.ref)

  defp schedule_heartbeat do
    :erlang.send_after(@heartbeat_interval, self(), :heartbeat)
  end

  defp notify(nil, _msg), do: :ok
  defp notify(pid, msg), do: send(pid, msg)

  defp unix_time do
    {{y, mo, d}, {h, mi, s}} = :erlang.universaltime()
    # Days from Unix epoch (1970-01-01) to date
    days = days_since_epoch(y, mo, d)
    days * 86400 + h * 3600 + mi * 60 + s
  end

  defp days_since_epoch(year, month, day) do
    # Days from 1970-01-01 to year-month-day
    y1 = year - 1
    # Days from year 0 to Dec 31 of (year-1)
    days_y = y1 * 365 + div(y1, 4) - div(y1, 100) + div(y1, 400)
    # Days from year 0 to Dec 31 of 1969
    epoch_days = 1969 * 365 + div(1969, 4) - div(1969, 100) + div(1969, 400)
    # Days in months for current year
    days_m = days_in_months(year, month)
    days_y - epoch_days + days_m + day - 1
  end

  defp days_in_months(_year, 1), do: 0
  defp days_in_months(year, 2), do: 31


  defp days_in_months(year, m) when m > 2 do
    leap = if rem(year, 4) == 0 and (rem(year, 100) != 0 or rem(year, 400) == 0), do: 1, else: 0
    month_days = {31, 28 + leap, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    Enum.reduce(1..(m - 1), 0, fn i, acc -> acc + :erlang.element(i, month_days) end)
  end
end
