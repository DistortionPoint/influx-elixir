defmodule InfluxElixir.Client.Local.LineProtocolEscape do
  @moduledoc """
  Line-protocol escaping: what each engine undoes in a name and in a string
  field, left to right.
  """

  # A raw name whose last byte is a backslash: `\\` at the end, since a
  # single one would have escaped the separator.
  @spec ends_in_backslash?(binary()) :: boolean()
  @doc false
  def ends_in_backslash?(""), do: false
  def ends_in_backslash?(raw), do: :binary.last(raw) == ?\\

  # A string field's inner text with `\"` and `\\` undone, left to right.
  @spec unescape_string_field(binary()) :: binary()
  @doc false
  def unescape_string_field(inner) do
    if :binary.match(inner, "\\") == :nomatch,
      do: inner,
      else: do_unescape_string(inner, <<>>)
  end

  defp do_unescape_string(<<>>, acc), do: acc

  defp do_unescape_string(<<?\\, c, rest::binary>>, acc) when c in [?\\, ?"],
    do: do_unescape_string(rest, <<acc::binary, c>>)

  defp do_unescape_string(<<c, rest::binary>>, acc),
    do: do_unescape_string(rest, <<acc::binary, c>>)

  # ---------------------------------------------------------------------------
  # Unescaping
  #
  # Both engines read a name left to right and undo an escape only where a
  # backslash precedes one of its characters; the sets differ (verified):
  #
  #   * InfluxDB 3 undoes `\\` as well, in every name; a measurement also
  #     takes `\,` and `\ `, any other name `\,`, `\ ` and `\=`; `\"` is
  #     never undone
  #   * InfluxDB 2 never undoes `\\` (a backslash is kept unless it precedes
  #     a code): a tag takes `\,`, `\ ` and `\=`, a field key and a
  #     measurement those and `\"`
  # ---------------------------------------------------------------------------

  @doc "Undoes line-protocol escaping in a measurement name (`\\ `, `\\,`, `\\\\`)."
  @spec unescape_measurement(binary()) :: binary()
  def unescape_measurement(str) do
    if :binary.match(str, "\\") == :nomatch,
      do: str,
      else: unescape_v3(str, [?\s, ?,], <<>>)
  end

  # A tag key or value, or a field key, of InfluxDB 3.
  @spec unescape_tag(binary()) :: binary()
  @doc false
  def unescape_tag(str) do
    if :binary.match(str, "\\") == :nomatch,
      do: str,
      else: unescape_v3(str, [?\s, ?,, ?=], <<>>)
  end

  @spec unescape_v3(binary(), [byte()], binary()) :: binary()
  defp unescape_v3(<<>>, _codes, acc), do: acc

  defp unescape_v3(<<?\\, c, rest::binary>>, codes, acc) do
    if c == ?\\ or c in codes,
      do: unescape_v3(rest, codes, <<acc::binary, c>>),
      else: unescape_v3(rest, codes, <<acc::binary, ?\\, c>>)
  end

  defp unescape_v3(<<c, rest::binary>>, codes, acc),
    do: unescape_v3(rest, codes, <<acc::binary, c>>)

  # InfluxDB 2: `codes` are the characters a backslash may precede.
  @spec unescape_v2(binary(), [byte()]) :: binary()
  @doc false
  def unescape_v2(str, codes) do
    if :binary.match(str, "\\") == :nomatch, do: str, else: unescape_v2(str, codes, <<>>)
  end

  defp unescape_v2(<<>>, _codes, acc), do: acc

  defp unescape_v2(<<?\\, c, rest::binary>>, codes, acc) do
    if c in codes,
      do: unescape_v2(rest, codes, <<acc::binary, c>>),
      else: unescape_v2(<<c, rest::binary>>, codes, <<acc::binary, ?\\>>)
  end

  defp unescape_v2(<<c, rest::binary>>, codes, acc),
    do: unescape_v2(rest, codes, <<acc::binary, c>>)
end
