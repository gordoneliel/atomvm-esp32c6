defmodule Radar do
  @rx_pin 2
  @tx_pin 3
  @baud 256_000

  def start_link do
    pid = spawn_link(__MODULE__, :init, [])
    {:ok, pid}
  end

  def init do
    # Give sensor time to boot and start transmitting
    :timer.sleep(2000)
    :io.format(~c"[Radar] starting UART0 rx=~p tx=~p baud=~p\n", [@rx_pin, @tx_pin, @baud])

    try do
      uart = :uart.open("UART1", [{:rx, @rx_pin}, {:tx, @tx_pin}, {:speed, @baud}])
      :io.format(~c"[Radar] UART opened: ~p\n", [uart])
      loop(uart, <<>>, 0)
    catch
      kind, reason ->
        :io.format(~c"[Radar] CRASHED: ~p ~p\n", [kind, reason])
    end
  end


  defp loop(uart, buf, count) do
    result = :uart.read(uart)

    # Unwrap {:ok, data} or handle other returns
    raw =
      case result do
        {:ok, bin} when is_binary(bin) -> bin
        bin when is_binary(bin) -> bin
        _ -> <<>>
      end

    {new_buf, new_count} =
      if byte_size(raw) > 0 do
        {process(<<buf::binary, raw::binary>>), count + 1}
      else
        :timer.sleep(50)
        {buf, count + 1}
      end

    loop(uart, new_buf, new_count)
  end

  # Match data frame header F4 F3 F2 F1 + 2-byte LE length
  defp process(<<0xF4, 0xF3, 0xF2, 0xF1, lo, hi, rest::binary>> = buf) do
    len = lo + hi * 256

    if byte_size(rest) >= len + 4 do
      <<frame::binary-size(len), footer::binary-size(4), remaining::binary>> = rest

      if footer == <<0xF8, 0xF7, 0xF6, 0xF5>> do
        parse(frame)
      else
        :io.format(~c"[Radar] bad footer, skipping frame\n")
      end

      process(remaining)
    else
      buf
    end
  end

  # Match command ACK header FD FC FB FA (skip command responses)
  defp process(<<0xFD, 0xFC, 0xFB, 0xFA, lo, hi, rest::binary>> = buf) do
    len = lo + hi * 256

    if byte_size(rest) >= len + 4 do
      <<_frame::binary-size(len), _footer::binary-size(4), remaining::binary>> = rest
      :io.format(~c"[Radar] command ACK received\n")
      process(remaining)
    else
      buf
    end
  end

  # Skip to next potential header byte (F4 for data, FD for command)
  defp process(<<_, rest::binary>>) do
    skip_to_header(rest)
  end

  defp process(<<>>), do: <<>>

  defp skip_to_header(<<0xF4, _::binary>> = buf), do: process(buf)
  defp skip_to_header(<<0xFD, _::binary>> = buf), do: process(buf)
  defp skip_to_header(<<_, rest::binary>>), do: skip_to_header(rest)
  defp skip_to_header(<<>>), do: <<>>

  # Normal mode: data_type=0x02, head=0xAA, 9 bytes target data, tail=0x55, cal=0x00
  defp parse(<<0x02, 0xAA, status, ml, mh, me, sl, sh, se, dl, dh, 0x55, 0x00>>) do
    move_dist = ml + mh * 256
    stat_dist = sl + sh * 256
    det_dist = dl + dh * 256

    status_str =
      case status do
        0x00 -> ~c"none"
        0x01 -> ~c"moving"
        0x02 -> ~c"still"
        0x03 -> ~c"both"
        _ -> ~c"?"
      end

    # :io.format(~c"[Radar] ~s | dist:~pcm move:~pcm(e:~p) still:~pcm(e:~p)\n", [
    #   status_str,
    #   det_dist,
    #   move_dist,
    #   me,
    #   stat_dist,
    #   se
    # ])

    # Send to BLE as readable UTF-8 string
    try do
      status_label = case status do
        0x00 -> "N"
        0x01 -> "M"
        0x02 -> "S"
        0x03 -> "B"
        _ -> "?"
      end
      msg = :io_lib.format(~c"~s ~p ~p ~p ~p ~p", [status_label, move_dist, me, stat_dist, se, det_dist])
      Ble.notify(:erlang.list_to_binary(msg))
    catch
      _, _ -> :ok
    end
  end

  # Engineering mode: data_type=0x01
  defp parse(<<0x01, 0xAA, _rest::binary>> = data) do
    :io.format(~c"[Radar] engineering frame (~p bytes)\n", [byte_size(data)])
  end

  defp parse(data) do
    :io.format(~c"[Radar] unknown frame: ~p (~p bytes)\n", [data, byte_size(data)])
  end
end
