defmodule InfluxElixir.Client.Local.InfluxQLRegex do
  @moduledoc false
  # The regular expressions of an InfluxQL statement (`=~ /re/`, `GROUP BY
  # /re/`, `SELECT /re/`, `FROM /re/`, `SHOW ... =~ /re/`), read as the engine
  # reads them. It hands the pattern to the Rust `regex` crate after its own
  # handling of backslashes (verified one letter at a time): `\d \D \w \W \s \S`
  # and the `\p \P \x` classes and escapes are kept, a backslash before any
  # other letter is dropped (`\b` is the letter `b`, there is no word boundary,
  # `\A` is `A`), before punctuation it escapes it. A digit after one is a back
  # reference the engine refuses, and `\u` a Unicode escape the double's engine
  # does not read.
  #
  # The crate has no look-around and no atomic groups: the engine's 500 for
  # those names the pattern and the place (verified):
  #
  #     Invalid regex
  #     caused by
  #     External error: regex parse error:
  #         (?=a)a
  #         ^^^
  #     error: look-around, including look-ahead and look-behind, is not supported
  #
  # (`unrecognized flag` for `(?>`). A pattern the double's engine cannot compile
  # is refused by name, not given another body.
  #
  # Every function throws `{:refused, message}` or `{:refused, {:engine, 500, body}}`.

  @kept_letters ~c"dDwWsSpPx"
  @look_around "look-around, including look-ahead and look-behind, is not supported"

  @doc "The pattern as the double's regex engine reads it, or a throw."
  @spec pattern(binary()) :: binary()
  def pattern(source) do
    regex = unescape(source, [])
    check_groups(regex)

    case Regex.compile(regex, "u") do
      {:ok, _compiled} ->
        regex

      {:error, _reason} ->
        throw({:refused, "unsupported InfluxQL (the regular expression /#{source}/)"})
    end
  end

  @doc "The compiled regular expression of `source`, or a throw."
  @spec compile(binary()) :: Regex.t()
  def compile(source) do
    {:ok, regex} = source |> pattern() |> Regex.compile("u")
    regex
  end

  @spec unescape(binary(), iodata()) :: binary()
  defp unescape(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp unescape(<<?\\, c, _rest::binary>>, _acc) when c in ?0..?9 or c in [?u, ?U],
    do: throw({:refused, "unsupported InfluxQL (the regular expression escape \\#{<<c>>})"})

  defp unescape(<<?\\, c, rest::binary>>, acc) when c in @kept_letters,
    do: unescape(rest, [<<?\\, c>> | acc])

  defp unescape(<<?\\, c, rest::binary>>, acc) when c in ?a..?z or c in ?A..?Z,
    do: unescape(rest, [<<c>> | acc])

  defp unescape(<<?\\, c::utf8, rest::binary>>, acc), do: unescape(rest, [<<?\\, c::utf8>> | acc])
  defp unescape(<<c::utf8, rest::binary>>, acc), do: unescape(rest, [<<c::utf8>> | acc])
  defp unescape(<<c, rest::binary>>, acc), do: unescape(rest, [<<c>> | acc])

  # The first group the crate cannot read, left to right, outside character
  # classes and after escapes.
  @spec check_groups(binary()) :: :ok
  defp check_groups(regex) do
    regex |> String.codepoints() |> scan(0, 0, regex)
  end

  defp scan([], _index, _class, _regex), do: :ok
  defp scan(["\\", _escaped | rest], index, class, regex), do: scan(rest, index + 2, class, regex)
  defp scan(["[" | rest], index, class, regex), do: scan(rest, index + 1, class + 1, regex)

  defp scan(["]" | rest], index, class, regex),
    do: scan(rest, index + 1, max(class - 1, 0), regex)

  defp scan(["(", "?", c | _rest], index, 0, regex) when c in ["=", "!"],
    do: group_error(regex, index, 3, @look_around)

  defp scan(["(", "?", "<", c | _rest], index, 0, regex) when c in ["=", "!"],
    do: group_error(regex, index, 4, @look_around)

  defp scan(["(", "?", ">" | _rest], index, 0, regex),
    do: group_error(regex, index + 2, 1, "unrecognized flag")

  defp scan(["(", "?", c | rest], index, 0, regex) when c in ["#", "(", "|"],
    do: scan_refuse(rest, index, c, regex)

  defp scan(["(", "?", "P", "=" | rest], index, 0, regex),
    do: scan_refuse(rest, index, "P=", regex)

  defp scan([_other | rest], index, class, regex), do: scan(rest, index + 1, class, regex)

  defp scan_refuse(_rest, _index, group, _regex),
    do: throw({:refused, "unsupported InfluxQL (the regular expression group (?#{group})"})

  @spec group_error(binary(), non_neg_integer(), pos_integer(), binary()) :: no_return()
  defp group_error(regex, column, width, message) do
    pointer = String.duplicate(" ", column) <> String.duplicate("^", width)

    body =
      "Invalid regex\ncaused by\nExternal error: regex parse error:\n" <>
        "    #{regex}\n    #{pointer}\nerror: #{message}"

    throw({:refused, {:engine, 500, body}})
  end
end
