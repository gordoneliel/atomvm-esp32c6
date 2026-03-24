defmodule Sesame.Channel.PlugCrypto do
  @moduledoc """
  Minimal Plug.Crypto.sign compatible token generation (plug_crypto 2.1.1).
  Token format: {data, signed_at_ms, max_age_seconds}
  """

  def sign(secret, salt, data, opts \\ []) do
    iterations = Keyword.get(opts, :key_iterations, 1000)
    length = Keyword.get(opts, :key_length, 32)
    signed_at_seconds = Keyword.get(opts, :signed_at, nil)
    signed_at_ms = if signed_at_seconds, do: signed_at_seconds * 1000, else: :erlang.system_time(:millisecond)
    max_age = Keyword.get(opts, :max_age, 86400)

    key = :crypto.pbkdf2_hmac(:sha256, secret, salt, iterations, length)

    protected = url_encode64(<<"HS256">>)
    payload = url_encode64(:erlang.term_to_binary({data, signed_at_ms, max_age}))
    signed = <<protected::binary, ".", payload::binary>>
    signature = url_encode64(:crypto.mac(:hmac, :sha256, key, signed))

    <<signed::binary, ".", signature::binary>>
  end

  defp url_encode64(data) do
    encoded = :base64.encode(data)
    url_safe(encoded, <<>>)
  end

  defp url_safe(<<>>, acc), do: acc
  defp url_safe(<<"=", rest::binary>>, acc), do: url_safe(rest, acc)
  defp url_safe(<<"+", rest::binary>>, acc), do: url_safe(rest, <<acc::binary, "-">>)
  defp url_safe(<<"/", rest::binary>>, acc), do: url_safe(rest, <<acc::binary, "_">>)
  defp url_safe(<<c, rest::binary>>, acc), do: url_safe(rest, <<acc::binary, c>>)
end
