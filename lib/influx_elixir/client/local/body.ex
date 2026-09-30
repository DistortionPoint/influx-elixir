defmodule InfluxElixir.Client.Local.Body do
  @moduledoc """
  Reads a write request's body as the engine does before it parses a line
  (verified against InfluxDB 3 Core and InfluxDB 2.7).

    * `gzip: true` (`Content-Encoding: gzip`) decompresses the body. It is
      the header that decides, not the bytes: a gzip body sent without it
      is parsed as line protocol, and a plain body sent with it fails.
      Concatenated gzip members are read as one body. InfluxDB 3 answers a
      body it cannot decompress with a 400
      `error decoding gzip stream: <reason>`: `unexpected end of file` (a
      body shorter than a gzip header, or cut short), `invalid gzip header`,
      `corrupt deflate stream`, or `corrupt gzip stream does not have a
      matching checksum`; InfluxDB 2 with its 500 `internal error`. Bytes
      after a complete gzip stream are not modelled exactly.
    * InfluxDB 3 then refuses a body that is not UTF-8 with a 400
      `body content is not valid utf8: ...`, naming the first bad byte as
      Rust's `Utf8Error` does. InfluxDB 2 stores the bytes as they are.
  """

  @gzip_header_size 10

  @doc """
  The body the engine parses, or its error for the profile.
  """
  @spec read(binary(), boolean(), atom()) :: {:ok, binary()} | {:error, map()}
  def read(body, gzip?, profile) do
    with {:ok, text} <- decompress(body, gzip?, profile) do
      check_utf8(text, profile)
    end
  end

  @spec decompress(binary(), boolean(), atom()) :: {:ok, binary()} | {:error, map()}
  defp decompress(body, false, _profile), do: {:ok, body}

  defp decompress(body, true, profile) do
    {:ok, :zlib.gunzip(body)}
  rescue
    ErlangError -> {:error, gzip_error(body, profile)}
  end

  @spec gzip_error(binary(), atom()) :: map()
  defp gzip_error(_body, :v2) do
    %{
      status: 500,
      body:
        Jason.encode!(%{
          "code" => "internal error",
          "message" => "An internal error has occurred - check server logs"
        })
    }
  end

  defp gzip_error(body, _v3),
    do: %{status: 400, body: "error decoding gzip stream: " <> why(body)}

  # `:zlib` says only `:data_error`; the engine's decoder says why.
  @spec why(binary()) :: binary()
  defp why(body) when byte_size(body) < @gzip_header_size, do: "unexpected end of file"
  defp why(<<0x1F, 0x8B, 8, _rest::binary>> = body), do: inflate_why(body)
  defp why(_body), do: "invalid gzip header"

  # Inflating as gzip raises on a corrupt stream or a bad checksum, and
  # stops short on a truncated one. A deflate stream that inflates on its
  # own (the header without optional fields) had only its checksum wrong.
  @spec inflate_why(binary()) :: binary()
  defp inflate_why(body) do
    <<_header::binary-size(@gzip_header_size), deflate::binary>> = body

    cond do
      inflates?(body, 31) -> "unexpected end of file"
      inflates?(deflate, -15) -> "corrupt gzip stream does not have a matching checksum"
      true -> "corrupt deflate stream"
    end
  end

  @spec inflates?(binary(), integer()) :: boolean()
  defp inflates?(data, window_bits) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, window_bits)
      _output = :zlib.inflate(z, data)
      true
    rescue
      ErlangError -> false
    after
      :zlib.close(z)
    end
  end

  @spec check_utf8(binary(), atom()) :: {:ok, binary()} | {:error, map()}
  defp check_utf8(text, :v2), do: {:ok, text}

  defp check_utf8(text, _v3) do
    case :unicode.characters_to_binary(text) do
      valid when is_binary(valid) ->
        {:ok, text}

      {:incomplete, good, _rest} ->
        utf8_error("incomplete utf-8 byte sequence from index #{byte_size(good)}")

      {:error, good, rest} ->
        utf8_error(
          "invalid utf-8 sequence of #{error_len(rest)} bytes from index #{byte_size(good)}"
        )
    end
  end

  @spec utf8_error(binary()) :: {:error, map()}
  defp utf8_error(reason),
    do: {:error, %{status: 400, body: "body content is not valid utf8: " <> reason}}

  # Rust's `Utf8Error::error_len`: how many bytes, from the first bad one,
  # form the longest prefix of a valid sequence before it goes wrong.
  @spec error_len(binary()) :: pos_integer()
  defp error_len(<<lead, rest::binary>>) do
    case sequence(lead) do
      {width, second} ->
        1 + valid_continuations(rest, [second | List.duplicate(0x80..0xBF, width - 2)])

      :invalid_lead ->
        1
    end
  end

  # The width of the sequence a lead byte starts, and the range its second
  # byte must fall in (narrower after E0, ED, F0 and F4, which exclude
  # overlong forms, surrogates and code points above U+10FFFF).
  @spec sequence(byte()) :: {2..4, Range.t()} | :invalid_lead
  defp sequence(lead) when lead in 0xC2..0xDF, do: {2, 0x80..0xBF}
  defp sequence(0xE0), do: {3, 0xA0..0xBF}
  defp sequence(0xED), do: {3, 0x80..0x9F}
  defp sequence(lead) when lead in 0xE1..0xEF, do: {3, 0x80..0xBF}
  defp sequence(0xF0), do: {4, 0x90..0xBF}
  defp sequence(0xF4), do: {4, 0x80..0x8F}
  defp sequence(lead) when lead in 0xF1..0xF3, do: {4, 0x80..0xBF}
  defp sequence(_lead), do: :invalid_lead

  @spec valid_continuations(binary(), [Range.t()]) :: non_neg_integer()
  defp valid_continuations(<<byte, rest::binary>>, [range | ranges]) do
    if byte in range, do: 1 + valid_continuations(rest, ranges), else: 0
  end

  defp valid_continuations(_rest, _ranges), do: 0
end
