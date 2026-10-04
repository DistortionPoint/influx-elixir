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
  # (`unrecognized flag` for `(?>`, and for any letter of a flag group the crate has none
  # for: `(?n)`). A pattern the double's engine cannot compile, and a flag group whose error
  # the double does not word, is refused by name, not given another body.
  #
  # Every function throws `{:refused, message}` or `{:refused, {:engine, 500, body}}`.

  alias InfluxElixir.Client.Local.InfluxQLError

  @kept_letters ~c"dDwWsSpPx"
  @look_around "look-around, including look-ahead and look-behind, is not supported"
  @flag_letters ["i", "m", "s", "U", "u", "x", "R"]
  @not_flags ["P", "<", "#", "(", "|", "=", "!"]

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

  @doc """
  The compiled regular expression of `source`, or a throw. `frame` says where the expression
  stands: in a condition (`:where`, the default: the engine's 500 for the crate's error), in
  `FROM` (`:from`) or among the columns of the select list, its function arguments and
  `GROUP BY` (`:expand`), where the planner wraps the same error as a 400 that names the
  expression (verified).
  """
  @spec compile(binary(), :where | :from | :expand) :: Regex.t()
  def compile(source, frame \\ :where) do
    {:ok, regex} = source |> pattern() |> Regex.compile("u")
    regex
  catch
    {:refused, {:engine, 500, body}} when frame != :where ->
      throw({:refused, {:engine, 400, planning_error(source, body, frame)}})
  end

  @spec planning_error(binary(), binary(), :from | :expand) :: binary()
  defp planning_error(source, body, frame) do
    [_frame, detail] = String.split(body, "External error: ", parts: 2)
    message = "invalid regular expression '/#{source}/': " <> detail

    case frame do
      :from -> "Error during planning: " <> message
      :expand -> InfluxQLError.expand_error(message)
    end
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

  defp scan(["(", "?", c | rest], index, 0, regex) when c in ["#", "(", "|"],
    do: scan_refuse(rest, index, c, regex)

  defp scan(["(", "?", "P", "=" | rest], index, 0, regex),
    do: scan_refuse(rest, index, "P=", regex)

  defp scan(["(", "?", c | rest], index, 0, regex) when c not in @not_flags do
    check_flags([c | rest], index + 2, [], "", regex)
    scan(["?", c | rest], index + 1, 0, regex)
  end

  defp scan([_other | rest], index, class, regex), do: scan(rest, index + 1, class, regex)

  # The flags of `(?flags)` and `(?flags:`, up to the character that ends them: a letter the
  # crate has no flag for is its error where it stands; the other faults of a flag group
  # (a repeated flag or negation, a negation with no flag after it, an end of the pattern)
  # are not worded by the double.
  @spec check_flags([binary()], non_neg_integer(), [binary()], binary(), binary()) ::
          :ok
  defp check_flags([], _at, _seen, _last, _regex), do: unworded_flags()

  defp check_flags([")" | _rest], at, [], _last, regex),
    do: group_error(regex, at - 1, 1, "repetition operator missing expression")

  defp check_flags([closer | _rest], at, _seen, last, regex) when closer in [")", ":"],
    do:
      if(last == "-",
        do: group_error(regex, at - 1, 1, "dangling flag negation operator"),
        else: :ok
      )

  defp check_flags(["-" | rest], at, seen, _last, regex) do
    if "-" in seen,
      do: unworded_flags(),
      else: check_flags(rest, at + 1, ["-" | seen], "-", regex)
  end

  # `R` is the crate's flag for CRLF line ends, where the double's engine reads recursion.
  defp check_flags(["R" | _rest], _at, _seen, _last, _regex), do: unworded_flags()

  defp check_flags([c | rest], at, seen, _last, regex) when c in @flag_letters do
    if c in seen,
      do: unworded_flags(),
      else: check_flags(rest, at + 1, [c | seen], c, regex)
  end

  defp check_flags([_other | _rest], at, _seen, _last, regex),
    do: group_error(regex, at, 1, "unrecognized flag")

  defp scan_refuse(_rest, _index, group, _regex),
    do: throw({:refused, "unsupported InfluxQL (the regular expression group (?#{group})"})

  @spec unworded_flags() :: no_return()
  defp unworded_flags,
    do:
      throw(
        {:refused,
         "unsupported InfluxQL (a regular expression flag group the double does not word)"}
      )

  @spec group_error(binary(), non_neg_integer(), pos_integer(), binary()) :: no_return()
  defp group_error(regex, column, width, message) do
    pointer = String.duplicate(" ", column) <> String.duplicate("^", width)

    body =
      "Invalid regex\ncaused by\nExternal error: regex parse error:\n" <>
        "    #{regex}\n    #{pointer}\nerror: #{message}"

    throw({:refused, {:engine, 500, body}})
  end
end
