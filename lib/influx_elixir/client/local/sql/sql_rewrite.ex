defmodule InfluxElixir.Client.Local.SQLRewrite do
  @moduledoc false
  # The spellings the engine's SQL parser reads as another (verified against
  # InfluxDB 3 Core), written the way the rest of `InfluxElixir.Client.Local`
  # reads them. The text is a statement `InfluxElixir.Client.Local.SQLLexer`
  # has scrubbed and `InfluxElixir.Client.Local.SQLSyntax` has read:
  #
  #   * `a == b` is `a = b`
  #   * `` `name` `` is `"name"`, a doubled backtick one backtick
  #   * `SELECT ALL x` is `SELECT x`
  #   * `FETCH FIRST n ROWS ONLY` is read and ignored, as the engine ignores
  #     it: `LIMIT` and `OFFSET` decide the rows
  #   * `FROM (t)` is `FROM t`, in any depth of parentheses
  #   * `FROM a, b` is `FROM a CROSS JOIN b`

  @typep token :: {:space | :word | :quoted | :backtick | :string | :symbol | :other, binary()}

  @symbols ["<=>", "!~*", "<>", "!=", "<=", ">=", "||", "~*", "!~", "<<", ">>", "::", "->", "=="]
  @from_ends ~w(WHERE GROUP HAVING ORDER LIMIT OFFSET FETCH UNION EXCEPT INTERSECT WINDOW QUALIFY)
  @not_names ~w(SELECT WITH VALUES LATERAL UNNEST TABLE)

  @doc "The statement with the engine's other spellings written as the ones the double reads."
  @spec apply(binary()) :: binary()
  def apply(sql) do
    sql
    |> tokens([])
    |> Enum.map(&spelled/1)
    |> select_all()
    |> offset_rows()
    |> fetch()
    |> from_lists(0, [], [])
    |> Enum.map_join(fn {_kind, text} -> text end)
  end

  # ---------------------------------------------------------------------------
  # Tokens
  # ---------------------------------------------------------------------------

  @spec tokens(binary(), [token()]) :: [token()]
  defp tokens(<<>>, acc), do: Enum.reverse(acc)

  defp tokens(<<c, _rest::binary>> = text, acc) when c in [?\s, ?\t, ?\r, ?\n] do
    [space] = Regex.run(~r/\A\s+/, text)
    tokens(tail(text, space), [{:space, space} | acc])
  end

  defp tokens(<<q, rest::binary>> = text, acc) when q in [?', ?", ?`] do
    case closing(rest, q) do
      {:ok, after_quote} ->
        kind = Map.fetch!(%{?' => :string, ?" => :quoted, ?` => :backtick}, q)
        quoted = binary_part(text, 0, byte_size(text) - byte_size(after_quote))
        tokens(after_quote, [{kind, quoted} | acc])

      :error ->
        Enum.reverse(acc, [{:other, text}])
    end
  end

  defp tokens(<<c::utf8, _rest::binary>> = text, acc) do
    cond do
      word_start?(c) ->
        [word] = Regex.run(~r/\A[\p{L}_][\p{L}\p{N}_$]*/u, text)
        tokens(tail(text, word), [{:word, word} | acc])

      c in ?0..?9 ->
        [number] = Regex.run(~r/\A\d[\p{L}\p{N}_.]*/u, text)
        tokens(tail(text, number), [{:other, number} | acc])

      true ->
        symbol = Enum.find(@symbols, &String.starts_with?(text, &1)) || <<c::utf8>>
        tokens(tail(text, symbol), [{:symbol, symbol} | acc])
    end
  end

  # The text after the quote that closes a quoted token, a doubled quote one inside.
  @spec closing(binary(), byte()) :: {:ok, binary()} | :error
  defp closing(<<q, q, rest::binary>>, q), do: closing(rest, q)
  defp closing(<<q, rest::binary>>, q), do: {:ok, rest}
  defp closing(<<_c::utf8, rest::binary>>, q), do: closing(rest, q)
  defp closing(<<>>, _q), do: :error

  @spec tail(binary(), binary()) :: binary()
  defp tail(text, taken),
    do: binary_part(text, byte_size(taken), byte_size(text) - byte_size(taken))

  @spec word_start?(integer()) :: boolean()
  defp word_start?(c) when c in ?a..?z or c in ?A..?Z or c == ?_, do: true
  defp word_start?(c) when c < 128, do: false
  defp word_start?(c), do: Regex.match?(~r/\A\p{L}\z/u, <<c::utf8>>)

  # ---------------------------------------------------------------------------
  # The spellings of a token
  # ---------------------------------------------------------------------------

  @spec spelled(token()) :: token()
  defp spelled({:symbol, "=="}), do: {:symbol, "="}
  defp spelled({:backtick, text}), do: {:quoted, double_quoted(text)}
  defp spelled(token), do: token

  # `` `a``b` `` names ``a`b``, which is written `"a`b"`.
  @spec double_quoted(binary()) :: binary()
  defp double_quoted(text) do
    name = text |> binary_part(1, byte_size(text) - 2) |> String.replace("``", "`")
    ~s|"| <> String.replace(name, ~s|"|, ~s|""|) <> ~s|"|
  end

  # ---------------------------------------------------------------------------
  # SELECT ALL
  # ---------------------------------------------------------------------------

  @spec select_all([token()]) :: [token()]
  defp select_all([{:word, select} | rest]) do
    with "SELECT" <- String.upcase(select),
         {blank, [{:word, all} | more]} <- Enum.split_while(rest, &space?/1),
         "ALL" <- String.upcase(all) do
      [{:word, select} | select_all(drop_space(blank, more))]
    else
      _other -> [{:word, select} | select_all(rest)]
    end
  end

  defp select_all([token | rest]), do: [token | select_all(rest)]
  defp select_all([]), do: []

  # The space that stood before `ALL` stands before what follows it, if anything did.
  @spec drop_space([token()], [token()]) :: [token()]
  defp drop_space(blank, [{:space, _text} | _more] = more), do: blank ++ more
  defp drop_space(blank, more), do: blank ++ more

  # ---------------------------------------------------------------------------
  # OFFSET n ROWS
  # ---------------------------------------------------------------------------

  # `OFFSET n ROW` and `OFFSET n ROWS` are `OFFSET n`.
  @spec offset_rows([token()]) :: [token()]
  defp offset_rows([{:word, word} | rest]) do
    with "OFFSET" <- String.upcase(word),
         {blank, [count | after_count]} <- Enum.split_while(rest, &space?/1),
         {:ok, count, after_count} <- offset_count(count, after_count),
         {_blank, [{:word, rows} | more]} <- Enum.split_while(after_count, &space?/1),
         true <- String.upcase(rows) in ["ROW", "ROWS"] do
      [{:word, word}] ++ blank ++ count ++ offset_rows(more)
    else
      _other -> [{:word, word} | offset_rows(rest)]
    end
  end

  defp offset_rows([token | rest]), do: [token | offset_rows(rest)]
  defp offset_rows([]), do: []

  defp offset_count({:other, number} = token, rest),
    do: if(Regex.match?(~r/\A\d/, number), do: {:ok, [token], rest}, else: :error)

  defp offset_count({:symbol, "$"} = dollar, [{kind, _name} = name | rest])
       when kind in [:word, :other],
       do: {:ok, [dollar, name], rest}

  defp offset_count(_token, _rest), do: :error

  # ---------------------------------------------------------------------------
  # FETCH
  # ---------------------------------------------------------------------------

  # `FETCH [FIRST | NEXT] [n] [PERCENT] [ROW | ROWS] [ONLY | WITH TIES]`, which the
  # engine reads and ignores.
  @spec fetch([token()]) :: [token()]
  defp fetch([{:word, word} | rest] = tokens) do
    if String.upcase(word) == "FETCH" and clause?(rest),
      do:
        rest
        |> skip_words(~w(FIRST NEXT))
        |> skip_quantity()
        |> skip_words(~w(PERCENT))
        |> skip_words(~w(ROW ROWS))
        |> skip_only()
        |> fetch(),
      else: [hd(tokens) | fetch(rest)]
  end

  defp fetch([token | rest]), do: [token | fetch(rest)]
  defp fetch([]), do: []

  # What follows a `FETCH` that is a clause: `FIRST`, `NEXT`, `ROW`, `ROWS` or a count.
  @spec clause?([token()]) :: boolean()
  defp clause?(tokens) do
    case Enum.drop_while(tokens, &space?/1) do
      [{:word, word} | _more] -> String.upcase(word) in ~w(FIRST NEXT ROW ROWS)
      [{:other, number} | _more] -> Regex.match?(~r/\A\d/, number)
      [{:string, _text} | _more] -> true
      _other -> false
    end
  end

  @spec skip_words([token()], [binary()]) :: [token()]
  defp skip_words(tokens, words) do
    case Enum.drop_while(tokens, &space?/1) do
      [{:word, word} | rest] -> if String.upcase(word) in words, do: rest, else: tokens
      _other -> tokens
    end
  end

  @spec skip_quantity([token()]) :: [token()]
  defp skip_quantity(tokens) do
    case Enum.drop_while(tokens, &space?/1) do
      [{:other, _number} | rest] ->
        rest

      [{:string, _text} | rest] ->
        rest

      [{:word, word} | rest] ->
        if String.upcase(word) in ~w(TRUE FALSE NULL), do: rest, else: tokens

      [{:symbol, "$"}, {kind, _name} | rest] when kind in [:word, :other] ->
        rest

      _other ->
        tokens
    end
  end

  @spec skip_only([token()]) :: [token()]
  defp skip_only(tokens) do
    case Enum.drop_while(tokens, &space?/1) do
      [{:word, word} | rest] ->
        case String.upcase(word) do
          "ONLY" -> rest
          "WITH" -> skip_words(rest, ["TIES"])
          _other -> tokens
        end

      _other ->
        tokens
    end
  end

  # ---------------------------------------------------------------------------
  # FROM
  # ---------------------------------------------------------------------------

  # `depths` are the parenthesis depths of the `FROM` lists being read, the innermost first.
  @spec from_lists([token()], non_neg_integer(), [non_neg_integer()], [token()]) :: [token()]
  defp from_lists([], _depth, _depths, acc), do: Enum.reverse(acc)

  defp from_lists([{:symbol, "("} = open | rest], depth, depths, acc),
    do: from_lists(rest, depth + 1, depths, [open | acc])

  defp from_lists([{:symbol, ")"} = close | rest], depth, depths, acc),
    do: from_lists(rest, depth - 1, Enum.reject(depths, &(&1 >= depth)), [close | acc])

  defp from_lists([{:symbol, ","} | rest], depth, [depth | _more] = depths, acc),
    do:
      from_lists(unparenthesized(rest), depth, depths, [
        {:word, "CROSS JOIN"},
        {:space, " "} | acc
      ])

  defp from_lists([{:word, word} = token | rest], depth, depths, acc) do
    case String.upcase(word) do
      "FROM" ->
        if distinct_before?(acc) do
          from_lists(rest, depth, depths, [token | acc])
        else
          from_lists(unparenthesized(rest), depth, [depth | depths], [token | acc])
        end

      "JOIN" ->
        from_lists(unparenthesized(rest), depth, depths, [token | acc])

      upper when upper in @from_ends ->
        from_lists(rest, depth, Enum.reject(depths, &(&1 == depth)), [token | acc])

      _other ->
        from_lists(rest, depth, depths, [token | acc])
    end
  end

  defp from_lists([token | rest], depth, depths, acc),
    do: from_lists(rest, depth, depths, [token | acc])

  # The `FROM` of `IS [NOT] DISTINCT FROM` starts no list.
  @spec distinct_before?([token()]) :: boolean()
  defp distinct_before?(acc) do
    case Enum.drop_while(acc, &space?/1) do
      [{:word, word} | _before] -> String.upcase(word) == "DISTINCT"
      _other -> false
    end
  end

  # `( name )` after `FROM`, `JOIN` or a comma, in any depth of parentheses, written `name`.
  @spec unparenthesized([token()]) :: [token()]
  defp unparenthesized(tokens) do
    {blank, rest} = Enum.split_while(tokens, &space?/1)

    case rest do
      [{:symbol, "("} | inner] ->
        case bare_name(inner) do
          {:ok, name, after_name} -> blank ++ unparenthesized(name ++ after_name)
          :error -> tokens
        end

      _other ->
        tokens
    end
  end

  # A name and the `)` that closes it, past the blank and the parentheses before the name,
  # and what follows the `)`.
  @spec bare_name([token()]) :: {:ok, [token()], [token()]} | :error
  defp bare_name(tokens) do
    {blank, rest} = Enum.split_while(tokens, &space?/1)

    case rest do
      [{:symbol, "("} | inner] ->
        with {:ok, name, after_name} <- bare_name(inner),
             [{:symbol, ")"} | more] <- Enum.drop_while(after_name, &space?/1) do
          {:ok, blank ++ name, more}
        else
          _not_a_name -> :error
        end

      [{kind, text} | more] when kind in [:word, :quoted] ->
        if kind == :word and String.upcase(text) in @not_names,
          do: :error,
          else: name_parts(more, [{kind, text}], blank)

      _other ->
        :error
    end
  end

  @spec name_parts([token()], [token()], [token()]) :: {:ok, [token()], [token()]} | :error
  defp name_parts([{:symbol, "."}, {kind, _text} = part | rest], acc, blank)
       when kind in [:word, :quoted],
       do: name_parts(rest, [part, {:symbol, "."} | acc], blank)

  defp name_parts(rest, acc, blank) do
    case Enum.drop_while(rest, &space?/1) do
      [{:symbol, ")"} | more] -> {:ok, blank ++ Enum.reverse(acc), more}
      _other -> :error
    end
  end

  @spec space?(token()) :: boolean()
  defp space?({:space, _text}), do: true
  defp space?(_token), do: false
end
