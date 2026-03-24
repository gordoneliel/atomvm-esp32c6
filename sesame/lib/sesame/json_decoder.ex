defmodule Sesame.JsonDecoder do
  @moduledoc """
  Minimal JSON decoder for Phoenix channel messages.
  Supports: arrays, objects, strings, integers, null, true, false.
  Objects decode to keyword lists. null decodes to nil.
  """

  def decode(bin) when is_binary(bin) do
    {value, _rest} = parse_value(skip_ws(bin))
    value
  end

  defp parse_value(<<"\"", rest::binary>>), do: parse_string(rest, <<>>)
  defp parse_value(<<"[", rest::binary>>), do: parse_array(skip_ws(rest), [])
  defp parse_value(<<"{", rest::binary>>), do: parse_object(skip_ws(rest), [])
  defp parse_value(<<"null", rest::binary>>), do: {nil, rest}
  defp parse_value(<<"true", rest::binary>>), do: {true, rest}
  defp parse_value(<<"false", rest::binary>>), do: {false, rest}
  defp parse_value(<<c, _::binary>> = bin) when c == ?- or (c >= ?0 and c <= ?9), do: parse_number(bin, <<>>)

  defp parse_string(<<"\\\"", rest::binary>>, acc), do: parse_string(rest, <<acc::binary, "\"">>)
  defp parse_string(<<"\\\\", rest::binary>>, acc), do: parse_string(rest, <<acc::binary, "\\">>)
  defp parse_string(<<"\\/", rest::binary>>, acc), do: parse_string(rest, <<acc::binary, "/">>)
  defp parse_string(<<"\\n", rest::binary>>, acc), do: parse_string(rest, <<acc::binary, "\n">>)
  defp parse_string(<<"\\r", rest::binary>>, acc), do: parse_string(rest, <<acc::binary, "\r">>)
  defp parse_string(<<"\\t", rest::binary>>, acc), do: parse_string(rest, <<acc::binary, "\t">>)
  defp parse_string(<<"\\b", rest::binary>>, acc), do: parse_string(rest, <<acc::binary, 8>>)
  defp parse_string(<<"\\u00", hex::binary-size(2), rest::binary>>, acc) do
    val = hex_to_int(hex)
    parse_string(rest, <<acc::binary, val>>)
  end
  defp parse_string(<<"\"", rest::binary>>, acc), do: {acc, rest}
  defp parse_string(<<c, rest::binary>>, acc), do: parse_string(rest, <<acc::binary, c>>)

  defp parse_number(<<c, rest::binary>>, acc) when c == ?- or (c >= ?0 and c <= ?9) do
    parse_number(rest, <<acc::binary, c>>)
  end

  defp parse_number(rest, acc) do
    {:erlang.binary_to_integer(acc), rest}
  end

  defp parse_array(<<"]", rest::binary>>, acc), do: {:lists.reverse(acc), rest}

  defp parse_array(bin, acc) do
    {value, rest} = parse_value(skip_ws(bin))
    rest2 = skip_ws(rest)

    case rest2 do
      <<",", rest3::binary>> -> parse_array(skip_ws(rest3), [value | acc])
      <<"]", rest3::binary>> -> {:lists.reverse([value | acc]), rest3}
    end
  end

  defp parse_object(<<"}", rest::binary>>, acc), do: {:lists.reverse(acc), rest}

  defp parse_object(bin, acc) do
    {key, rest} = parse_value(skip_ws(bin))
    <<":", rest2::binary>> = skip_ws(rest)
    {value, rest3} = parse_value(skip_ws(rest2))
    rest4 = skip_ws(rest3)
    entry = {safe_to_atom(key), value}

    case rest4 do
      <<",", rest5::binary>> -> parse_object(skip_ws(rest5), [entry | acc])
      <<"}", rest5::binary>> -> {:lists.reverse([entry | acc]), rest5}
    end
  end

  defp skip_ws(<<c, rest::binary>>) when c == ?\s or c == ?\t or c == ?\n or c == ?\r do
    skip_ws(rest)
  end

  defp skip_ws(bin), do: bin

  defp safe_to_atom(key) when is_binary(key) do
    :erlang.binary_to_atom(key, :utf8)
  end

  defp hex_to_int(<<h, l>>) do
    hex_digit(h) * 16 + hex_digit(l)
  end

  defp hex_digit(c) when c >= ?0 and c <= ?9, do: c - ?0
  defp hex_digit(c) when c >= ?a and c <= ?f, do: c - ?a + 10
  defp hex_digit(c) when c >= ?A and c <= ?F, do: c - ?A + 10
end
