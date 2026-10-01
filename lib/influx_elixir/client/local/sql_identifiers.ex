defmodule InfluxElixir.Client.Local.SQLIdentifiers do
  @moduledoc """
  DataFusion's identifier rules, applied to a SQL text before
  `InfluxElixir.Client.Local.SQLParser` reads it (verified against
  InfluxDB 3 Core):

    * an unquoted identifier is folded to lower case — column, table, alias
      and CTE names alike: `SELECT Host FROM Cpu` reads column `host` of
      table `cpu`, and `AVG(v) AS Avg_V` answers `avg_v`. Only the ASCII
      letters fold: `Fé` is `fé`, and `FÉ` is `fÉ`, a column that does not
      exist. A name may hold letters and digits of any script
    * a double-quoted identifier keeps its case: `"Host"` is column `Host`
    * string literals (`'Abc'`) and `$name` placeholders are left as they are

  A quoted identifier that is a plain word is written back bare, so the
  parser — which folds nothing — sees its exact name. One that needs its
  quotes (a space, a dot, a keyword such as `"order"`) keeps them.
  """

  # Words the parser reads as structure: a quoted column of that name keeps
  # its quotes rather than turn into the keyword.
  @keywords ~w(select distinct on from where and or not in is null between like ilike
               group by order asc desc nulls first last limit offset as with cross join
               interval true false cast having union)

  @doc "Folds unquoted identifiers to lower case and unwraps plain quoted ones."
  @spec normalize(binary()) :: binary()
  def normalize(sql), do: sql |> scan([]) |> IO.iodata_to_binary()

  @spec scan(binary(), iodata()) :: iodata()
  defp scan(<<>>, acc), do: Enum.reverse(acc)

  defp scan(<<?', rest::binary>>, acc) do
    {literal, rest} = take_quoted(rest, ?', [])
    scan(rest, [[?', literal, ?'] | acc])
  end

  defp scan(<<?", rest::binary>>, acc) do
    {name, rest} = take_quoted(rest, ?", [])
    scan(rest, [quoted_identifier(IO.iodata_to_binary(name)) | acc])
  end

  defp scan(<<?$, rest::binary>>, acc) do
    {name, rest} = take_word(rest, [])
    scan(rest, [[?$, name] | acc])
  end

  # A number (`1e5`, `2.5`) is copied whole, so its exponent is not a word.
  defp scan(<<c, _rest::binary>> = sql, acc) when c in ?0..?9 do
    {number, rest} = take_word(sql, [])
    scan(rest, [number | acc])
  end

  defp scan(<<c::utf8, rest::binary>> = sql, acc) do
    if word_start?(c) do
      {word, rest} = take_word(sql, [])
      scan(rest, [String.downcase(IO.iodata_to_binary(word), :ascii) | acc])
    else
      scan(rest, [<<c::utf8>> | acc])
    end
  end

  # The body of a '...' or "..." token; a doubled quote inside it is kept
  # doubled, as the parser reads it. An unterminated token takes the rest.
  @spec take_quoted(binary(), char(), iodata()) :: {iodata(), binary()}
  defp take_quoted(<<q, q, rest::binary>>, q, acc), do: take_quoted(rest, q, [q, q | acc])
  defp take_quoted(<<q, rest::binary>>, q, acc), do: {Enum.reverse(acc), rest}

  defp take_quoted(<<c::utf8, rest::binary>>, q, acc),
    do: take_quoted(rest, q, [<<c::utf8>> | acc])

  defp take_quoted(<<>>, _q, acc), do: {Enum.reverse(acc), <<>>}

  # An identifier starts with a letter or `_` and goes on with letters,
  # digits and `_`, in any script.
  @spec take_word(binary(), iodata()) :: {iodata(), binary()}
  defp take_word(<<c::utf8, rest::binary>> = input, acc) do
    if word_char?(c), do: take_word(rest, [<<c::utf8>> | acc]), else: {Enum.reverse(acc), input}
  end

  defp take_word(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  @spec word_start?(char()) :: boolean()
  defp word_start?(c) when c in ?a..?z or c in ?A..?Z or c == ?_, do: true
  defp word_start?(c) when c < 128, do: false
  defp word_start?(c), do: Regex.match?(~r/\A\p{L}\z/u, <<c::utf8>>)

  @spec word_char?(char()) :: boolean()
  defp word_char?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_, do: true
  defp word_char?(c) when c < 128, do: false
  defp word_char?(c), do: Regex.match?(~r/\A[\p{L}\p{N}]\z/u, <<c::utf8>>)

  @spec quoted_identifier(binary()) :: iodata()
  defp quoted_identifier(name) do
    if Regex.match?(~r/\A[\p{L}_][\p{L}\p{N}_]*\z/u, name) and
         String.downcase(name) not in @keywords,
       do: name,
       else: [?", name, ?"]
  end
end
