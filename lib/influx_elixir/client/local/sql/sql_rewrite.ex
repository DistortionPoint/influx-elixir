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
  #   * `SELECT ... INTO name` is `SELECT ...`: the engine plans the select and then refuses
  #     to create the table, which `into?/1` says
  #   * a word of the grammar after `AS` (`AS having`) is a name: it is written quoted

  alias InfluxElixir.Client.Local.SQLIdentifiers

  @typep token :: {:space | :word | :quoted | :backtick | :string | :symbol | :other, binary()}

  @symbols [
    "<=>",
    "!~~*",
    "!~~",
    "~~*",
    "~~",
    "//",
    "!~*",
    "<>",
    "!=",
    "<=",
    ">=",
    "||",
    "~*",
    "!~",
    "<<",
    ">>",
    "::",
    "->",
    "=="
  ]
  @from_ends ~w(WHERE GROUP HAVING ORDER LIMIT OFFSET FETCH UNION EXCEPT INTERSECT WINDOW QUALIFY)
  @not_names ~w(SELECT WITH VALUES LATERAL UNNEST TABLE)
  @structural ~w(SELECT FROM WHERE GROUP HAVING ORDER LIMIT OFFSET FETCH UNION EXCEPT INTERSECT
    MINUS WINDOW QUALIFY WITH JOIN INNER LEFT RIGHT FULL CROSS NATURAL OUTER ON USING DISTINCT
    ALL)
  # Words after which a word is an operand: it begins an item or an expression.
  @operand_words ~w(SELECT DISTINCT ALL AS AND OR NOT XOR IS IN LIKE ILIKE BETWEEN CASE WHEN
    THEN ELSE)

  @doc "Whether the statement (a plain `SELECT`, once `SQLSyntax` has read it) has an `INTO`."
  @spec into?(binary()) :: boolean()
  def into?(sql) do
    Regex.match?(~r/\binto\b/i, sql) and
      sql |> tokens([]) |> without_into() |> elem(1)
  end

  @doc "The statement with the engine's other spellings written as the ones the double reads."
  @spec apply(binary()) :: binary()
  def apply(sql) do
    sql
    |> tokens([])
    |> without_into()
    |> elem(0)
    |> Enum.map(&spelled/1)
    |> keyword_aliases()
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
    case SQLIdentifiers.take_quoted(rest, q) do
      {:ok, _body, after_quote} ->
        kind = Map.fetch!(%{?' => :string, ?" => :quoted, ?` => :backtick}, q)
        quoted = binary_part(text, 0, byte_size(text) - byte_size(after_quote))
        tokens(after_quote, [{kind, quoted} | acc])

      :error ->
        Enum.reverse(acc, [{:other, text}])
    end
  end

  defp tokens(<<c::utf8, _rest::binary>> = text, acc) do
    cond do
      SQLIdentifiers.word_start?(c) ->
        [word] = Regex.run(~r/\A[\p{L}_][\p{L}\p{N}_$]*/u, text)
        tokens(tail(text, word), [{:word, word} | acc])

      c in ?0..?9 or (c == ?. and digit_next?(text)) ->
        {number, rest} = SQLIdentifiers.take_number(text)
        tokens(rest, [{:other, number} | acc])

      true ->
        symbol = Enum.find(@symbols, &String.starts_with?(text, &1)) || <<c::utf8>>
        tokens(tail(text, symbol), [{:symbol, symbol} | acc])
    end
  end

  @spec digit_next?(binary()) :: boolean()
  defp digit_next?(<<?., d, _rest::binary>>), do: d in ?0..?9
  defp digit_next?(_text), do: false

  @spec tail(binary(), binary()) :: binary()
  defp tail(text, taken),
    do: binary_part(text, byte_size(taken), byte_size(text) - byte_size(taken))

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
  # INTO
  # ---------------------------------------------------------------------------

  # The tokens without the `INTO name` of the statement's select list, and whether it had one.
  # An `INTO` where an item begins is a column's name (`SELECT into`, `SELECT n + into`).
  @spec without_into([token()]) :: {[token()], boolean()}
  defp without_into(tokens) do
    case split_into(tokens, [], nil) do
      nil ->
        {tokens, false}

      {before, after_into} ->
        if select_list?(before),
          do: {before ++ drop_target(after_into), true},
          else: {tokens, false}
    end
  end

  # The tokens before the first `INTO` that follows a complete item (or the comma of a trailing
  # one) and those after it; `nil` when there is none.
  @spec split_into([token()], [token()], token() | nil) :: {[token()], [token()]} | nil
  defp split_into([], _before, _previous), do: nil

  defp split_into([token | rest], before, previous) do
    cond do
      into_word?(token) and (item_end?(previous) or previous == {:symbol, ","}) ->
        {Enum.reverse(before), rest}

      space?(token) ->
        split_into(rest, [token | before], previous)

      true ->
        split_into(rest, [token | before], following(token, previous))
    end
  end

  @spec into_word?(token()) :: boolean()
  defp into_word?({:word, word}), do: String.upcase(word) == "INTO"
  defp into_word?(_token), do: false

  # What the next token is read after: a `*` is the wildcard of an item where no expression
  # ends before it (that wildcard ends the item), and a multiplication otherwise.
  @spec following(token(), token() | nil) :: token()
  defp following({:symbol, "*"} = star, previous),
    do: if(item_end?(previous), do: star, else: {:other, "*"})

  defp following(token, _previous), do: token

  # Whether the token before is the end of an expression, so that a word after it begins no
  # item and no operand: not the start of the list (`SELECT`, `DISTINCT`, `ALL`), a comma, an
  # opening bracket, an operator or a word that takes an operand.
  @spec item_end?(token() | nil) :: boolean()
  defp item_end?({kind, _text}) when kind in [:quoted, :string, :other], do: true
  defp item_end?({:symbol, symbol}), do: symbol in [")", "]"]
  defp item_end?({:word, word}), do: String.upcase(word) not in @operand_words
  defp item_end?(_start), do: false

  # Whether the tokens are a select list still open: a `SELECT` as the first token, no `FROM`
  # outside parentheses yet, and the last token not an `AS`.
  @spec select_list?([token()]) :: boolean()
  defp select_list?(tokens) do
    case Enum.reject(tokens, &space?/1) do
      [{:word, select} | _rest] = significant ->
        String.upcase(select) == "SELECT" and open_list?(significant)

      _other ->
        false
    end
  end

  @spec open_list?([token()]) :: boolean()
  defp open_list?(significant) do
    {depth, from?} =
      Enum.reduce(significant, {0, false}, fn
        {:symbol, "("}, {depth, from?} -> {depth + 1, from?}
        {:symbol, ")"}, {depth, from?} -> {depth - 1, from?}
        {:word, word}, {0, _from?} = state -> if from?(word), do: {0, true}, else: state
        _other, state -> state
      end)

    depth == 0 and not from? and not as?(List.last(significant))
  end

  @spec from?(binary()) :: boolean()
  defp from?(word), do: String.upcase(word) == "FROM"

  @spec as?(token()) :: boolean()
  defp as?({:word, word}), do: String.upcase(word) == "AS"
  defp as?(_token), do: false

  # The target's tokens: `[TEMP[ORARY]] [UNLOGGED] [TABLE] name[.name]*`.
  @spec drop_target([token()]) :: [token()]
  defp drop_target(tokens) do
    tokens
    |> drop_words(["TEMP", "TEMPORARY"])
    |> drop_words(["UNLOGGED"])
    |> drop_words(["TABLE"])
    |> drop_name()
  end

  @spec drop_words([token()], [binary()]) :: [token()]
  defp drop_words(tokens, words) do
    case Enum.drop_while(tokens, &space?/1) do
      [{:word, word} | rest] = found -> if String.upcase(word) in words, do: rest, else: found
      other -> other
    end
  end

  @spec drop_name([token()]) :: [token()]
  defp drop_name(tokens) do
    case Enum.drop_while(tokens, &space?/1) do
      [{kind, _name}, {:symbol, "."} | rest] when kind in [:word, :quoted, :string] ->
        drop_name(rest)

      [{kind, _name} | rest] when kind in [:word, :quoted, :string] ->
        [{:space, " "} | rest]

      other ->
        other
    end
  end

  # ---------------------------------------------------------------------------
  # A keyword as an alias
  # ---------------------------------------------------------------------------

  # The engine takes any word after an `AS` as the name (`SELECT host AS having`), which the
  # clause readers would take for the clause: it is quoted. An `AS` where an item begins is a
  # column's name, and the name after an `AS` is not another `AS` (`host AS as`).
  @spec keyword_aliases([token()]) :: [token()]
  defp keyword_aliases(tokens), do: keyword_aliases(tokens, nil)

  @spec keyword_aliases([token()], token() | nil) :: [token()]
  defp keyword_aliases([{:word, as} = token | rest], previous) do
    with "AS" <- String.upcase(as),
         true <- item_end?(previous),
         {blank, [{:word, name} | more]} <- Enum.split_while(rest, &space?/1) do
      [token | blank] ++ [alias_name(name) | keyword_aliases(more, {:word, name})]
    else
      _plain -> [token | keyword_aliases(rest, token)]
    end
  end

  defp keyword_aliases([{:space, _text} = token | rest], previous),
    do: [token | keyword_aliases(rest, previous)]

  defp keyword_aliases([token | rest], previous),
    do: [token | keyword_aliases(rest, following(token, previous))]

  defp keyword_aliases([], _previous), do: []

  @spec alias_name(binary()) :: token()
  defp alias_name(name) do
    if String.upcase(name) in @structural,
      do: {:quoted, ~s|"| <> String.downcase(name) <> ~s|"|},
      else: {:word, name}
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
