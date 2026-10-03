defmodule InfluxElixir.Client.Local.SQLQualifier do
  @moduledoc false
  # The table names a query's columns may be qualified with, for
  # `InfluxElixir.Client.Local.SQLParser`: the table's name or its alias, and for
  # `FROM w CROSS JOIN ref` the right side's. The double reads one table per
  # query, so a qualifier adds nothing and is dropped from the text, after its
  # use is recorded: the engine names a column it cannot find as it was written
  # (`t.nosuch`).

  alias InfluxElixir.Client.Local.{LineProtocolParser, SQLLiteral, SQLMask, SQLTable}

  # `FROM w CROSS JOIN ref [AS r]`: the right side is taken out of the text
  # (the rest of the parser sees one table) and recorded with its alias so
  # its qualifiers can be dropped like the left side's.
  # Keywords that can follow a table name are clauses (or constructs), never an alias.
  @not_an_alias ~w(AS WHERE GROUP ORDER LIMIT JOIN CROSS INNER LEFT RIGHT FULL OUTER NATURAL UNION EXCEPT INTERSECT HAVING OFFSET ON USING)

  @cross_join_pattern ~r/(?i)(\bFROM\s+(?:"[^"]+"|(?:[^\s\\]|\\.)+)(?:\s+(?:AS\s+)?(?!CROSS\b)\w+)?)\s+CROSS\s+JOIN\s+("[^"]+"|(?:[^\s\\]|\\.)+)(?:\s+(?:AS\s+)?(?!(?:#{Enum.join(@not_an_alias, "|")})\b)(\w+))?/u

  @doc """
  Takes the right side of a `CROSS JOIN` out of the text, with the names it is
  known by.
  """
  @spec split_cross_join(binary()) :: {binary(), {binary(), [binary()]} | nil}
  def split_cross_join(sql) do
    case Regex.run(@cross_join_pattern, hidden_mask(sql), return: :index) do
      [{start, length}, left, table | alias_name] ->
        name = sql |> SQLMask.cut(table) |> table_name()
        names = [name | Enum.map(alias_name, &SQLMask.cut(sql, &1))]
        tail = binary_part(sql, start + length, byte_size(sql) - start - length)
        {binary_part(sql, 0, start) <> SQLMask.cut(sql, left) <> tail, {name, names}}

      nil ->
        {sql, nil}
    end
  end

  # `SELECT w.bid FROM q AS w WHERE w.provider = 'a'` — one table per query,
  # so a qualifier (the table name or its alias) adds nothing: drop the
  # alias from FROM and the `qualifier.` prefixes outside string literals.
  # A keyword after the table is a clause (or an unsupported construct that
  # `check_clauses/1` will name), never an alias.
  @from_alias_pattern ~r/(?i)(FROM\s+("[^"]+"|(?:[^\s\\]|\\.)+))(?:\s+(?:AS\s+)?(?!(?:#{Enum.join(@not_an_alias, "|")})\b)(\w+))?/u

  @doc """
  The text without the qualifiers of its table (and of the joined one), the
  name the table is known by, and the qualifier each column was written with.
  """
  @spec strip(binary(), {binary(), [binary()]} | nil) ::
          {binary(), binary(), %{binary() => binary()}}
  def strip(sql, cross_join) do
    # The joined table is known by its alias when it has one, by its name
    # otherwise.
    joined_names =
      case cross_join do
        {_table, names} -> [List.last(names)]
        nil -> []
      end

    case Regex.run(@from_alias_pattern, hidden_mask(sql), return: :index) do
      [{start, length}, from_clause, _table, alias_name] ->
        # The alias (with its `AS`) is whatever follows the table in the match.
        {from_start, from_length} = from_clause
        after_match = start + length

        without_alias =
          binary_part(sql, 0, from_start + from_length) <>
            binary_part(sql, after_match, byte_size(sql) - after_match)

        # Once the table has an alias the engine knows it by that name alone
        # (`xqa.v` is an unknown relation after `FROM xqa AS t`).
        alias_text = SQLMask.cut(sql, alias_name)
        {text, qualified} = drop_qualifiers(without_alias, [alias_text | joined_names])
        {text, alias_text, qualified}

      [_full, _from_clause, table] ->
        table_text = table_name(SQLMask.cut(sql, table))
        also = table_qualifiers(SQLMask.cut(sql, table), table_text)
        {text, qualified} = drop_qualifiers(sql, [table_text | also] ++ joined_names)
        {text, table_text, qualified}

      nil ->
        {sql, "", %{}}
    end
  end

  # A bare table is also known by the tails of its full name (`m` is
  # `iox.m` and `public.iox.m`); a quoted one only by its name.
  @spec table_qualifiers(binary(), binary()) :: [binary()]
  defp table_qualifiers("\"" <> _quoted, _table_text), do: []
  defp table_qualifiers(_raw, table_text), do: SQLTable.qualifiers(table_text)

  # The text with its strings blanked and the `FROM` of a function and of
  # `IS DISTINCT FROM` hidden: what is left is the `FROM` of the query.
  @spec hidden_mask(binary()) :: binary()
  defp hidden_mask(sql), do: sql |> SQLMask.mask() |> SQLMask.hide_inner_from()

  # A table as the engine names it: a quoted one without its quotes, a
  # doubled quote one quote.
  @spec table_name(binary()) :: binary()
  defp table_name("\"" <> _rest = quoted), do: SQLLiteral.identifier_name(quoted)
  defp table_name(bare), do: LineProtocolParser.unescape_measurement(bare)

  # A qualifier is the table's name or its alias, bare or quoted; a quoted
  # one is dropped only when it is exactly the name (the engine reads
  # `"XQA".v` as another relation).
  #
  # Returns the text without them, and the qualifier each column was written
  # with: the engine names a column it cannot find as it was written
  # (`t.nosuch`).
  @spec drop_qualifiers(binary(), [binary()]) :: {binary(), %{binary() => binary()}}
  defp drop_qualifiers(sql, qualifiers) do
    qualifiers = Enum.reject(qualifiers, &(&1 == ""))
    names = qualifiers |> Enum.map_join("|", &Regex.escape/1)

    quoted =
      Enum.map_join(qualifiers, "|", &Regex.escape(~s("#{String.replace(&1, ~s("), ~s(""))}")))

    pattern =
      ~r/'(?:[^']|'')*'|(?:#{quoted})\.(?=[\w"])|"[^"]*"|(?<![\w."])(?:#{names})\.(?=\w)/u

    qualified =
      pattern
      |> Regex.scan(sql, return: :index)
      |> Enum.flat_map(fn [{start, length} | _groups] ->
        token = binary_part(sql, start, length)
        after_token = binary_part(sql, start + length, byte_size(sql) - start - length)

        if qualifier_token?(token), do: written_with(token, after_token), else: []
      end)
      |> Map.new()

    stripped =
      Regex.replace(pattern, sql, fn token ->
        if qualifier_token?(token), do: "", else: token
      end)

    {stripped, qualified}
  end

  # A match that is a qualifier: not a string literal, and a quoted token
  # only when the dot after it is part of it.
  @spec qualifier_token?(binary()) :: boolean()
  defp qualifier_token?("'" <> _rest), do: false
  defp qualifier_token?("\"" <> _rest = token), do: String.ends_with?(token, "\".")
  defp qualifier_token?(_bare), do: true

  # `[{column, qualifier}]` for the column that follows a qualifier.
  @spec written_with(binary(), binary()) :: [{binary(), binary()}]
  defp written_with(token, rest) do
    qualifier = token |> String.trim_trailing(".") |> bare_identifier()

    case Regex.run(~r/\A(?:("(?:[^"]|"")*")|(\w+))/u, rest) do
      [_full, column] -> [{bare_identifier(column), qualifier}]
      [_full, "", column] -> [{column, qualifier}]
      nil -> []
    end
  end

  @spec bare_identifier(binary()) :: binary()
  defp bare_identifier(text) do
    if SQLLiteral.identifier?(text), do: SQLLiteral.identifier_name(text), else: text
  end
end
