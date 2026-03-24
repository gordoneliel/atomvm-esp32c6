defmodule Sesame.Channel.LocalShell do
  @moduledoc """
  Remote shell for AtomVM over NervesHub local_shell extension.
  Input format: `:mod.fun(arg1, arg2)` or `Mod.fun(arg1)`
  No String module dependency — uses only binary ops and :erlang/:binary.
  """

  def eval(input) do
    trimmed = trim(input)
    case parse(trimmed) do
      {:ok, mod, fun, args} ->
        try do
          result = apply(mod, fun, args)
          <<(inspect_safe(result))::binary, "\r\n">>
        catch
          kind, err ->
            <<"\r\n** (", :erlang.atom_to_binary(kind)::binary, ") ",
              inspect_safe(err)::binary, "\r\n">>
        end
      {:error, reason} ->
        <<"** ", reason::binary, "\r\n">>
    end
  end

  # --- Parser ---

  defp parse(<<>>), do: {:error, "empty input"}

  defp parse(input) do
    case parse_mod_fun_args(input) do
      {:ok, _, _, _} = result -> result
      :error -> {:error, "syntax: :mod.fun(args) or Mod.fun(args)"}
    end
  end

  # Find the module and function by scanning for dots
  # Strategy: find last dot before '(' or end of string
  defp parse_mod_fun_args(input) do
    case find_last_dot(input) do
      {mod_str, fun_and_args} ->
        mod = to_module(mod_str)
        case split_fun_args(fun_and_args) do
          {fun_str, args_str} ->
            fun = :erlang.binary_to_atom(fun_str)
            case parse_args(args_str) do
              {:ok, args} -> {:ok, mod, fun, args}
              err -> err
            end
          :no_args ->
            fun = :erlang.binary_to_atom(trim(fun_and_args))
            {:ok, mod, fun, []}
        end
      :error ->
        :error
    end
  end

  defp find_last_dot(bin) do
    find_last_dot(bin, 0, -1)
  end

  defp find_last_dot(bin, pos, last_dot) when pos >= byte_size(bin) do
    if last_dot >= 0 do
      mod = :binary.part(bin, 0, last_dot)
      rest = :binary.part(bin, last_dot + 1, byte_size(bin) - last_dot - 1)
      {mod, rest}
    else
      :error
    end
  end

  defp find_last_dot(bin, pos, last_dot) do
    case :binary.at(bin, pos) do
      ?. -> find_last_dot(bin, pos + 1, pos)
      ?( ->
        # Stop here — use last_dot we found
        if last_dot >= 0 do
          mod = :binary.part(bin, 0, last_dot)
          rest = :binary.part(bin, last_dot + 1, byte_size(bin) - last_dot - 1)
          {mod, rest}
        else
          :error
        end
      _ -> find_last_dot(bin, pos + 1, last_dot)
    end
  end

  defp to_module(<<":", name::binary>>), do: :erlang.binary_to_atom(name)
  defp to_module(name), do: :erlang.binary_to_atom(<<"Elixir.", name::binary>>)

  defp split_fun_args(str) do
    case :binary.match(str, <<"(">>) do
      {pos, 1} ->
        fun_str = :binary.part(str, 0, pos)
        # Find matching closing paren
        rest = :binary.part(str, pos + 1, byte_size(str) - pos - 1)
        # Strip trailing ')'
        args_str = strip_trailing_paren(rest)
        {fun_str, args_str}
      :nomatch ->
        :no_args
    end
  end

  defp strip_trailing_paren(bin) do
    len = byte_size(bin)
    if len > 0 and :binary.at(bin, len - 1) == ?) do
      :binary.part(bin, 0, len - 1)
    else
      bin
    end
  end

  defp parse_args(<<>>), do: {:ok, []}
  defp parse_args(str) do
    parts = split_comma(trim(str))
    try do
      {:ok, Enum.map(parts, fn p -> parse_arg(trim(p)) end)}
    catch
      _, reason -> {:error, <<"bad argument: ", inspect_safe(reason)::binary>>}
    end
  end

  defp split_comma(bin), do: split_comma(bin, <<>>, 0, [])

  defp split_comma(<<>>, acc, _depth, results) do
    case trim(acc) do
      <<>> -> :lists.reverse(results)
      trimmed -> :lists.reverse([trimmed | results])
    end
  end

  defp split_comma(<<",", rest::binary>>, acc, 0, results) do
    split_comma(rest, <<>>, 0, [trim(acc) | results])
  end

  defp split_comma(<<"(", rest::binary>>, acc, depth, results) do
    split_comma(rest, <<acc::binary, "(">>, depth + 1, results)
  end

  defp split_comma(<<")", rest::binary>>, acc, depth, results) when depth > 0 do
    split_comma(rest, <<acc::binary, ")">>, depth - 1, results)
  end

  defp split_comma(<<"[", rest::binary>>, acc, depth, results) do
    split_comma(rest, <<acc::binary, "[">>, depth + 1, results)
  end

  defp split_comma(<<"]", rest::binary>>, acc, depth, results) when depth > 0 do
    split_comma(rest, <<acc::binary, "]">>, depth - 1, results)
  end

  defp split_comma(<<c, rest::binary>>, acc, depth, results) do
    split_comma(rest, <<acc::binary, c>>, depth, results)
  end

  defp parse_arg(<<":", rest::binary>>), do: :erlang.binary_to_atom(rest)
  defp parse_arg(<<"\"", _::binary>> = str) do
    # Strip quotes
    len = byte_size(str)
    :binary.part(str, 1, len - 2)
  end
  defp parse_arg(<<"true">>), do: true
  defp parse_arg(<<"false">>), do: false
  defp parse_arg(<<"nil">>), do: nil
  defp parse_arg(<<c, _::binary>> = str) when c >= ?0 and c <= ?9 do
    :erlang.binary_to_integer(str)
  end
  defp parse_arg(<<"-", c, _::binary>> = str) when c >= ?0 and c <= ?9 do
    :erlang.binary_to_integer(str)
  end
  defp parse_arg(<<c, _::binary>> = str) when c >= ?A and c <= ?Z do
    :erlang.binary_to_atom(<<"Elixir.", str::binary>>)
  end
  defp parse_arg(str), do: :erlang.error({:bad_arg, str})

  # --- Helpers ---

  defp trim(<<" ", rest::binary>>), do: trim(rest)
  defp trim(<<"\t", rest::binary>>), do: trim(rest)
  defp trim(<<"\n", rest::binary>>), do: trim(rest)
  defp trim(<<"\r", rest::binary>>), do: trim(rest)
  defp trim(bin), do: trim_trailing(bin)

  defp trim_trailing(bin) do
    len = byte_size(bin)
    if len > 0 do
      case :binary.at(bin, len - 1) do
        c when c == ?\s or c == ?\t or c == ?\n or c == ?\r ->
          trim_trailing(:binary.part(bin, 0, len - 1))
        _ -> bin
      end
    else
      bin
    end
  end

  defp inspect_safe(term) do
    try do
      :erlang.iolist_to_binary(:io_lib.format(~c"~p", [term]))
    catch
      _, _ -> <<"<unrepresentable>">>
    end
  end
end
