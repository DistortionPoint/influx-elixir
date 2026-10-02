defmodule InfluxElixir.TestSupport.Tokens do
  @moduledoc """
  Shape checks for a created token, whose secret, hash and creation time
  are generated and so cannot be compared to a literal.
  """

  @secret ~r/\Aapiv3_[A-Za-z0-9_-]{20,}\z/
  @hash ~r/\A[0-9a-f]{128}\z/

  @doc """
  The result of a token creation without the generated fields, once those
  have the shape the engine gives them; anything else is returned
  unchanged, so a comparison against the stable part fails on it.

  The secret is `apiv3_` and a url-safe random string, the hash is the 128
  hex digits of a SHA-512, and the creation time is RFC 3339.
  """
  @spec public(term()) :: term()
  def public({:ok, %{} = token}) do
    if generated?(token),
      do: {:ok, Map.drop(token, ["token", "hash", "created_at"])},
      else: {:ok, token}
  end

  def public(other), do: other

  @spec generated?(map()) :: boolean()
  defp generated?(%{"token" => secret, "hash" => hash, "created_at" => created_at})
       when is_binary(secret) and is_binary(hash) and is_binary(created_at) do
    Regex.match?(@secret, secret) and Regex.match?(@hash, hash) and
      match?({:ok, _datetime, 0}, DateTime.from_iso8601(created_at))
  end

  defp generated?(_token), do: false
end
