defmodule InfluxElixir.Client.Local.SQLSyntax do
  @moduledoc false
  # The parser errors the engine's SQL parser gives a `SELECT` that is not
  # well formed, for `InfluxElixir.Client.Local` (verified against InfluxDB 3
  # Core, over texts with a token left out, repeated, or put in the wrong
  # place):
  #
  #     SQL error: ParserError("Expected: an expression, found: EOF")
  #     SQL error: ParserError("Expected: end of statement, found: by at Line: 1, Column: 31")
  #
  # The text is read as the parser reads it: a recursive descent over the
  # tokens in which a word that is not a keyword with a meaning of its own in
  # that place is an identifier (`WHERE order BY` is a column called `order`
  # and then a stray `BY`), and a keyword whose own syntax does not parse is an
  # identifier too (`NOT` with nothing after it). The first token that cannot
  # continue the statement is named, with the line and column it starts at,
  # counted in characters.
  #
  # Only a text this grammar reads is judged. A construct it does not read (a
  # window, a `JOIN`, an `ARRAY`, a token it does not know) ends the check
  # without a verdict and leaves the text to the rest of the double, which
  # answers it or refuses it by name.

  alias InfluxElixir.Client.Local.{SQLError, SQLLexer, SQLStatement}

  @top {__MODULE__, :top}
  @refusal {__MODULE__, :refusal}

  @typep token :: {atom(), binary(), binary(), pos_integer(), pos_integer()}
  @typep tokens :: [token()]

  # Words that are not taken as the alias of a select item or a table.
  @alias_reserved ~w(FROM INTO WITH EXPLAIN ANALYZE SELECT WHERE GROUP SORT HAVING ORDER PIVOT
    UNPIVOT TOP LATERAL VIEW LIMIT OFFSET FETCH UNION EXCEPT INTERSECT MINUS ON JOIN INNER CROSS
    FULL LEFT RIGHT NATURAL USING CLUSTER DISTRIBUTE GLOBAL ANTI SEMI RETURNING ASOF OUTER SET
    QUALIFY WINDOW END FOR PARTITION PREWHERE SETTINGS FORMAT START CONNECT)

  # Words with a syntax of their own that this grammar does not read, and
  # words read as a call whose arguments have one.
  @opaque_words ~w(EXISTS ARRAY STRUCT MAP CONVERT MATCH PRIOR LISTAGG)
  @special_calls ~w(TRY_CAST SAFE_CAST EXTRACT CEIL FLOOR POSITION SUBSTRING SUBSTR OVERLAY TRIM)
  @typed_literals ~w(DATE TIME TIMESTAMP DATETIME)
  @after_call_bail ~w(FILTER OVER WITHIN IGNORE RESPECT)
  @interval_units ~w(YEAR YEARS MONTH MONTHS WEEK WEEKS DAY DAYS HOUR HOURS MINUTE MINUTES SECOND
    SECONDS MILLISECOND MILLISECONDS MICROSECOND MICROSECONDS NANOSECOND NANOSECONDS)
  @operators ~w(= == <=> <> != < > <= >= + - * / % || ~ !~ ~* !~* & | ^ << >>)
  @predicate_words ~w(IS IN BETWEEN LIKE ILIKE)
  @negatable_words ~w(IN BETWEEN LIKE ILIKE)
  @join_words ~w(JOIN INNER LEFT RIGHT FULL CROSS NATURAL OUTER STRAIGHT_JOIN)
  @logical_words ~w(AND OR XOR)
  @bound_operators ~w(+ - * / % ||)
  @table_function {__MODULE__, :table_function}

  @symbols [
    "<=>",
    "==",
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
    "(",
    ")",
    ",",
    ".",
    "*",
    "+",
    "-",
    "/",
    "%",
    "=",
    "<",
    ">",
    "~",
    "&",
    "|",
    "^",
    "[",
    "]",
    ":"
  ]

  @doc """
  `:ok` when the text reads as a statement (or this grammar cannot say), else
  the engine's parser error.
  """
  @spec check(binary()) :: :ok | {:error, SQLError.t()}
  def check(sql) do
    case tokenize(sql, 1, 1, []) do
      {:ok, tokens} -> tokens |> statement() |> flagged()
      :bail -> :ok
    end
  after
    Process.delete(@table_function)
    Process.delete(@top)
    Process.delete(@refusal)
  end

  @doc """
  `:ok`, or the engine's parser error for the first of the statements of a text
  that does not read, each read at the line and column it stands at in the whole
  text.
  """
  @spec check_statements(binary()) :: :ok | {:error, SQLError.t()}
  def check_statements(sql) do
    sql
    |> split()
    |> Enum.reduce_while(:ok, fn {offset, piece}, :ok ->
      positioned = blank(binary_part(sql, 0, offset)) <> piece
      statement = String.replace_suffix(positioned, ";", "")

      case SQLStatement.parser_error(statement) do
        nil -> verdict(check(positioned))
        error -> {:halt, {:error, error}}
      end
    end)
  end

  defp verdict(:ok), do: {:cont, :ok}
  defp verdict({:error, _error} = error), do: {:halt, error}

  # The text with every character but a newline blank, so a statement keeps its line and
  # column in the whole text.
  @spec blank(binary()) :: binary()
  defp blank(text), do: Regex.replace(~r/[^\n]/u, text, " ")

  # The statements of a text, each with the byte at which it starts. A `;` inside a string,
  # a quoted name, a comment or a dollar-quoted string ends nothing.
  @spec split(binary()) :: [{non_neg_integer(), binary()}]
  defp split(sql), do: split(sql, 0, 0, [])

  defp split(sql, pos, start, acc) when pos >= byte_size(sql),
    do: Enum.reverse([piece(sql, start, pos) | acc])

  defp split(sql, pos, start, acc) do
    rest = binary_part(sql, pos, byte_size(sql) - pos)

    case rest do
      <<?;, _after::binary>> ->
        split(sql, pos + 1, pos + 1, [piece(sql, start, pos + 1) | acc])

      <<q, quoted::binary>> when q in [?', ?", ?`] ->
        split(sql, skip_quoted(sql, pos + 1, q, quoted), start, acc)

      <<"--", _after::binary>> ->
        split(sql, skip_line(sql, pos + 2), start, acc)

      <<"/*", _after::binary>> ->
        split(sql, skip_comment(sql, pos + 2, 1), start, acc)

      <<?$, _after::binary>> ->
        split(sql, skip_dollar(sql, pos, rest), start, acc)

      <<e, ?', body::binary>> when e in [?E, ?e] ->
        if word_before?(sql, pos),
          do: split(sql, pos + 1, start, acc),
          else: split(sql, skip_escaped(sql, pos + 2, body), start, acc)

      _other ->
        split(sql, pos + 1, start, acc)
    end
  end

  defp piece(sql, start, stop), do: {start, binary_part(sql, start, stop - start)}

  # The position after the quote that closes a quoted token, a doubled quote one inside.
  defp skip_quoted(sql, pos, q, <<q, q, rest::binary>>), do: skip_quoted(sql, pos + 2, q, rest)
  defp skip_quoted(_sql, pos, q, <<q, _rest::binary>>), do: pos + 1
  defp skip_quoted(sql, pos, q, <<_byte, rest::binary>>), do: skip_quoted(sql, pos + 1, q, rest)
  defp skip_quoted(sql, _pos, _q, <<>>), do: byte_size(sql)

  defp skip_line(sql, pos) when pos >= byte_size(sql), do: byte_size(sql)

  defp skip_line(sql, pos) do
    case :binary.match(sql, "\n", scope: {pos, byte_size(sql) - pos}) do
      {at, _length} -> at
      :nomatch -> byte_size(sql)
    end
  end

  defp skip_comment(sql, pos, _depth) when pos >= byte_size(sql), do: byte_size(sql)

  defp skip_comment(sql, pos, depth) do
    case binary_part(sql, pos, min(2, byte_size(sql) - pos)) do
      "*/" -> if depth == 1, do: pos + 2, else: skip_comment(sql, pos + 2, depth - 1)
      "/*" -> skip_comment(sql, pos + 2, depth + 1)
      _other -> skip_comment(sql, pos + 1, depth)
    end
  end

  # A dollar-quoted string, or the position after a placeholder's `$`.
  defp skip_dollar(sql, pos, rest) do
    case Regex.run(~r/\A\$([\p{L}\p{N}_]*)\$/u, rest) do
      [open, _tag] ->
        after_open = pos + byte_size(open)

        case :binary.match(sql, open, scope: {after_open, byte_size(sql) - after_open}) do
          {at, length} -> at + length
          :nomatch -> byte_size(sql)
        end

      nil ->
        pos + 1
    end
  end

  defp word_before?(_sql, 0), do: false
  defp word_before?(sql, pos), do: Regex.match?(~r/[\p{L}\p{N}_]/u, last_character(sql, pos))

  defp last_character(sql, pos) do
    sql |> binary_part(0, pos) |> String.last() |> Kernel.||("")
  end

  # The position after the closing quote of an escape string whose body starts at `pos`.
  defp skip_escaped(sql, pos, body) do
    case SQLLexer.escaped(body) do
      {:ok, _text, rest} -> byte_size(sql) - byte_size(rest)
      :error -> byte_size(sql)
    end
    |> max(pos)
  end

  # What a text that reads is still answered with: the engine's `TOP` is no feature of its
  # planner (405), and a spelling the double cannot read is refused by name.
  @spec flagged(:ok | {:error, SQLError.t()}) :: :ok | {:error, SQLError.t()}
  defp flagged(:ok) do
    cond do
      Process.get(@top) ->
        {:error, %{status: 405, body: "This feature is not implemented: TOP"}}

      reason = Process.get(@refusal) ->
        {:error, SQLError.refusal(reason)}

      Process.get(@table_function) ->
        {:error, SQLError.refusal("a table function in FROM: the engine has none")}

      true ->
        :ok
    end
  end

  defp flagged(error), do: error

  @spec refuse(binary()) :: :ok
  defp refuse(reason) do
    Process.put(@refusal, reason)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tokens: `{kind, printed, upper, line, column}`
  # ---------------------------------------------------------------------------

  @spec tokenize(binary(), pos_integer(), pos_integer(), tokens()) :: {:ok, tokens()} | :bail
  defp tokenize(<<>>, line, col, acc),
    do: {:ok, Enum.reverse([{:eof, "EOF", "EOF", line, col} | acc])}

  defp tokenize(<<?;, _rest::binary>>, line, col, acc),
    do: tokenize(<<>>, line, col + 1, [{:symbol, ";", ";", line, col} | acc])

  defp tokenize(<<?\n, rest::binary>>, line, _col, acc), do: tokenize(rest, line + 1, 1, acc)

  defp tokenize(<<c, rest::binary>>, line, col, acc) when c in [?\s, ?\t, ?\r],
    do: tokenize(rest, line, col + 1, acc)

  defp tokenize(<<"--", rest::binary>>, line, col, acc) do
    case :binary.split(rest, "\n") do
      [_comment] -> tokenize(<<>>, line, col, acc)
      [_comment, after_line] -> tokenize(after_line, line + 1, 1, acc)
    end
  end

  defp tokenize(<<"/*", rest::binary>>, line, col, acc),
    do: block_comment(rest, 1, line, col + 2, acc)

  defp tokenize(<<?', rest::binary>> = text, line, col, acc),
    do: quoted(text, rest, ?', :string, line, col, acc)

  defp tokenize(<<?", rest::binary>> = text, line, col, acc),
    do: quoted(text, rest, ?", :quoted, line, col, acc)

  defp tokenize(<<?`, rest::binary>> = text, line, col, acc),
    do: quoted(text, rest, ?`, :quoted, line, col, acc)

  defp tokenize(<<c::utf8, _rest::binary>> = text, line, col, acc) do
    cond do
      c in ?0..?9 or (c == ?. and digit_next?(text)) -> number(text, line, col, acc)
      word_start?(c) -> word(text, line, col, acc)
      c == ?$ -> placeholder(text, line, col, acc)
      true -> symbol(text, line, col, acc)
    end
  end

  defp tokenize(_invalid, _line, _col, _acc), do: :bail

  @spec digit_next?(binary()) :: boolean()
  defp digit_next?(<<?., d, _rest::binary>>), do: d in ?0..?9
  defp digit_next?(_text), do: false

  @spec block_comment(binary(), pos_integer(), pos_integer(), pos_integer(), tokens()) ::
          {:ok, tokens()} | :bail
  defp block_comment(<<"*/", rest::binary>>, 1, line, col, acc),
    do: tokenize(rest, line, col + 2, acc)

  defp block_comment(<<"*/", rest::binary>>, depth, line, col, acc),
    do: block_comment(rest, depth - 1, line, col + 2, acc)

  defp block_comment(<<"/*", rest::binary>>, depth, line, col, acc),
    do: block_comment(rest, depth + 1, line, col + 2, acc)

  defp block_comment(<<?\n, rest::binary>>, depth, line, _col, acc),
    do: block_comment(rest, depth, line + 1, 1, acc)

  defp block_comment(<<_c::utf8, rest::binary>>, depth, line, col, acc),
    do: block_comment(rest, depth, line, col + 1, acc)

  defp block_comment(_end_of_text, _depth, _line, _col, _acc), do: :bail

  # A string or a quoted identifier, its doubled quotes one quote inside. It
  # prints as the engine's tokenizer prints it: the text between the quotes,
  # undoubled, in the quotes.
  @spec quoted(binary(), binary(), byte(), atom(), pos_integer(), pos_integer(), tokens()) ::
          {:ok, tokens()} | :bail
  defp quoted(text, rest, mark, kind, line, col, acc) do
    case take_quoted(rest, mark, []) do
      {:ok, body, after_quote} ->
        raw = binary_part(text, 0, byte_size(text) - byte_size(after_quote))
        printed = <<mark>> <> body <> <<mark>>
        {next_line, next_col} = advance(raw, line, col)
        tokenize(after_quote, next_line, next_col, [{kind, printed, printed, line, col} | acc])

      :error ->
        :bail
    end
  end

  @spec take_quoted(binary(), byte(), [binary()]) :: {:ok, binary(), binary()} | :error
  defp take_quoted(<<mark, mark, rest::binary>>, mark, acc),
    do: take_quoted(rest, mark, [<<mark>> | acc])

  defp take_quoted(<<mark, rest::binary>>, mark, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_quoted(<<c::utf8, rest::binary>>, mark, acc),
    do: take_quoted(rest, mark, [<<c::utf8>> | acc])

  defp take_quoted(_text, _mark, _acc), do: :error

  # The line and column after `text`, which starts at `line`, `col`.
  @spec advance(binary(), pos_integer(), pos_integer()) :: {pos_integer(), pos_integer()}
  defp advance(text, line, col) do
    case String.split(text, "\n") do
      [single] -> {line, col + String.length(single)}
      parts -> {line + length(parts) - 1, String.length(List.last(parts)) + 1}
    end
  end

  # `0x1F` is a binary value to the engine, printed `X'1F'`, which the double refuses by
  # name once the text reads.
  @spec number(binary(), pos_integer(), pos_integer(), tokens()) :: {:ok, tokens()} | :bail
  defp number(text, line, col, acc) do
    case Regex.run(~r/\A0x([0-9a-fA-F]*)/, text) do
      [raw, digits] ->
        refuse(
          "a hexadecimal number (0x...) is a binary value on the engine, which this double does not model"
        )

        raw_token(text, raw, :literal, "X'" <> digits <> "'", line, col, acc)

      nil ->
        [literal] = Regex.run(~r/\A(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/, text)
        emit(text, literal, :number, line, col, acc)
    end
  end

  # A token of the text as written, which may span lines, printed as the engine prints it.
  @spec raw_token(binary(), binary(), atom(), binary(), pos_integer(), pos_integer(), tokens()) ::
          {:ok, tokens()} | :bail
  defp raw_token(text, raw, kind, printed, line, col, acc) do
    {next_line, next_col} = advance(raw, line, col)
    token = {kind, printed, printed, line, col}
    tokenize(binary_tail(text, raw), next_line, next_col, [token | acc])
  end

  # A one-letter word directly before a quote prefixes a string: `E'..'` is read (it prints
  # decoded, `E'a'b'` for `E'a''b'`), `N'..'` and the others are not.
  @spec word(binary(), pos_integer(), pos_integer(), tokens()) :: {:ok, tokens()} | :bail
  defp word(text, line, col, acc) do
    [literal] = Regex.run(~r/\A[\p{L}_][\p{L}\p{N}_$]*/u, text)
    after_word = binary_tail(text, literal)

    if String.length(literal) == 1 and String.starts_with?(after_word, "'") do
      if literal in ["E", "e"], do: escape_string(text, after_word, line, col, acc), else: :bail
    else
      emit(text, literal, :word, line, col, acc)
    end
  end

  @spec escape_string(binary(), binary(), pos_integer(), pos_integer(), tokens()) ::
          {:ok, tokens()} | :bail
  defp escape_string(text, <<?', body::binary>>, line, col, acc) do
    case SQLLexer.escaped(body) do
      {:ok, decoded, rest} ->
        raw = binary_part(text, 0, byte_size(text) - byte_size(rest))
        raw_token(text, raw, :literal, "E'" <> decoded <> "'", line, col, acc)

      :error ->
        :bail
    end
  end

  @spec binary_tail(binary(), binary()) :: binary()
  defp binary_tail(text, literal),
    do: binary_part(text, byte_size(literal), byte_size(text) - byte_size(literal))

  @spec placeholder(binary(), pos_integer(), pos_integer(), tokens()) ::
          {:ok, tokens()} | :bail
  defp placeholder(text, line, col, acc) do
    case dollar_string(text) do
      {:ok, raw} ->
        raw_token(text, raw, :literal, raw, line, col, acc)

      :none ->
        case Regex.run(~r/\A\$[\p{L}\p{N}_]*/u, text) do
          [literal] -> emit(text, literal, :placeholder, line, col, acc)
          nil -> :bail
        end

      :bail ->
        :bail
    end
  end

  # `$$..$$` and `$tag$..$tag$`, as written.
  @spec dollar_string(binary()) :: {:ok, binary()} | :none | :bail
  defp dollar_string(text) do
    case Regex.run(~r/\A\$([\p{L}\p{N}_]*)\$/u, text) do
      [open, _tag] ->
        case :binary.split(binary_tail(text, open), open) do
          [body, _after] -> {:ok, open <> body <> open}
          [_unterminated] -> :bail
        end

      nil ->
        :none
    end
  end

  @spec symbol(binary(), pos_integer(), pos_integer(), tokens()) :: {:ok, tokens()} | :bail
  defp symbol(text, line, col, acc) do
    case Enum.find(@symbols, &String.starts_with?(text, &1)) do
      nil -> :bail
      "!=" -> emit(text, "!=", :symbol, line, col, acc, "<>")
      symbol -> emit(text, symbol, :symbol, line, col, acc)
    end
  end

  @spec emit(
          binary(),
          binary(),
          atom(),
          pos_integer(),
          pos_integer(),
          tokens(),
          binary() | nil
        ) :: {:ok, tokens()} | :bail
  defp emit(text, literal, kind, line, col, acc, printed \\ nil) do
    token = {kind, printed || literal, String.upcase(literal), line, col}
    tokenize(binary_tail(text, literal), line, col + String.length(literal), [token | acc])
  end

  @spec word_start?(integer()) :: boolean()
  defp word_start?(c) when c in ?a..?z or c in ?A..?Z or c == ?_, do: true
  defp word_start?(c) when c < 128, do: false
  defp word_start?(c), do: Regex.match?(~r/\A\p{L}\z/u, <<c::utf8>>)

  # ---------------------------------------------------------------------------
  # The statement
  # ---------------------------------------------------------------------------

  @spec statement(tokens()) :: :ok | {:error, SQLError.t()}
  defp statement([{:word, _printed, first, _line, _col} | _rest] = tokens)
       when first in ["SELECT", "WITH"],
       do: read_query(tokens)

  defp statement([{:symbol, _printed, "(", _line, _col} | _rest] = tokens),
    do: read_query(tokens)

  defp statement(_tokens), do: :ok

  @spec read_query(tokens()) :: :ok | {:error, SQLError.t()}
  defp read_query(tokens) do
    case query(tokens) do
      [{:eof, _printed, _upper, _line, _col}] -> :ok
      [{:symbol, _printed, ";", _line, _col}, {:eof, _p, _u, _l, _c}] -> :ok
      [token | _rest] -> {:error, parser_error("end of statement", token)}
    end
  catch
    {:syntax, expected, token} -> {:error, parser_error(expected, token)}
    {:fail, error} -> {:error, error}
    :bail -> :ok
  end

  @spec parser_error(binary(), token()) :: SQLError.t()
  defp parser_error(expected, {:eof, _printed, _upper, _line, _col}),
    do: SQLError.parser("Expected: #{expected}, found: EOF")

  defp parser_error(expected, {_kind, printed, _upper, line, col}),
    do:
      SQLError.parser("Expected: #{expected}, found: #{printed} at Line: #{line}, Column: #{col}")

  @spec fail(binary(), tokens()) :: no_return()
  defp fail(expected, [token | _rest]), do: throw({:syntax, expected, token})

  @spec query(tokens()) :: tokens()
  defp query(tokens) do
    tokens
    |> with_clause()
    |> select_term()
    |> set_operations()
    |> order_by()
    |> limit_offset()
    |> fetch_clause()
  end

  defp with_clause([{:word, _p, "WITH", _l, _c} | rest]), do: common_tables(rest)
  defp with_clause(tokens), do: tokens

  defp common_tables([
         {kind, _p, _u, _l, _c},
         {:word, _q, "AS", _l2, _c2},
         {:symbol, _s, "(", _l3, _c3} | rest
       ])
       when kind in [:word, :quoted] do
    case rest |> query() |> close_paren() do
      [{:symbol, _t, ",", _l4, _c4} | more] -> common_tables(more)
      after_tables -> after_tables
    end
  end

  defp common_tables([{:word, _p, "RECURSIVE", _l, _c} | _rest]), do: throw(:bail)

  defp common_tables([{kind, _p, _u, _l, _c}, {:symbol, _q, "(", _l2, _c2} | _rest])
       when kind in [:word, :quoted],
       do: throw(:bail)

  defp common_tables([{kind, _p, _u, _l, _c} | _rest] = tokens) when kind in [:word, :quoted],
    do: fail("AS", tl(tokens))

  defp common_tables(tokens), do: fail("identifier", tokens)

  defp select_term([{:symbol, _p, "(", _l, _c} | rest]), do: rest |> query() |> close_paren()
  defp select_term([{:word, _p, "SELECT", _l, _c} | rest]), do: select_core(rest)
  defp select_term(tokens), do: fail("SELECT, VALUES, or a subquery in the query body", tokens)

  defp set_operations([{:word, _p, operator, _l, _c} | rest])
       when operator in ["UNION", "EXCEPT", "INTERSECT"] do
    case rest do
      [{:word, _q, quantifier, _l2, _c2} | more] when quantifier in ["ALL", "DISTINCT"] ->
        more |> select_term() |> set_operations()

      _plain ->
        rest |> select_term() |> set_operations()
    end
  end

  defp set_operations(tokens), do: tokens

  # ---------------------------------------------------------------------------
  # SELECT ... [FROM] [WHERE] [GROUP BY] [HAVING]
  # ---------------------------------------------------------------------------

  @spec select_core(tokens()) :: tokens()
  defp select_core(tokens) do
    tokens
    |> select_head()
    |> projection()
    |> from_clause()
    |> condition_clause("WHERE")
    |> group_by()
    |> condition_clause("HAVING")
  end

  # The quantifier and the `TOP` clause, in either order. The engine reads `TOP` and then
  # answers that it has no such feature (405), after every parser error of the text.
  defp select_head(tokens) do
    after_quantifier = select_quantifier(tokens)

    case top_clause(after_quantifier) do
      ^after_quantifier -> after_quantifier
      after_top -> select_quantifier(after_top)
    end
  end

  defp top_clause([{:word, _p, "TOP", _l, _c} | rest]) do
    Process.put(@top, true)
    rest |> top_quantity() |> top_percent() |> top_ties()
  end

  defp top_clause(tokens), do: tokens

  defp top_quantity([{:symbol, _p, "(", _l, _c} | rest]),
    do: rest |> expression() |> close_paren()

  defp top_quantity([{:number, _p, _u, _l, _c} | rest]), do: rest
  defp top_quantity(tokens), do: fail("literal int", tokens)

  defp top_percent([{:word, _p, "PERCENT", _l, _c} | rest]), do: rest
  defp top_percent(tokens), do: tokens

  defp top_ties([{:word, _p, "WITH", _l, _c}, {:word, _q, "TIES", _l2, _c2} | rest]), do: rest
  defp top_ties(tokens), do: tokens

  defp select_quantifier([
         {:word, _p, "ALL", line, col},
         {:word, _q, "DISTINCT", _l2, _c2} | _rest
       ]) do
    throw(
      {:fail,
       SQLError.parser("Cannot specify both ALL and DISTINCT at Line: #{line}, Column: #{col}")}
    )
  end

  defp select_quantifier([{:word, _p, "DISTINCT", _l, _c}, {:word, _q, "ON", _l2, _c2} | _rest]),
    do: throw(:bail)

  defp select_quantifier([{:word, _p, quantifier, _l, _c} | rest])
       when quantifier in ["DISTINCT", "ALL"],
       do: rest

  defp select_quantifier(tokens), do: tokens

  # `SELECT FROM t` selects no column.
  defp projection([{:word, _p, "FROM", _l, _c} | _rest] = tokens), do: tokens
  defp projection(tokens), do: tokens |> select_item() |> after_item()

  # A comma may end the list: before the end of the text, a closing bracket
  # or a word that cannot begin an item.
  defp after_item([{:symbol, _p, ",", _l, _c} | rest]) do
    case rest do
      [{:eof, _q, _u, _l2, _c2} | _more] -> rest
      [{:symbol, _q, bracket, _l2, _c2} | _more] when bracket in [")", "]"] -> rest
      [{:word, _q, upper, _l2, _c2} | _more] when upper in @alias_reserved -> rest
      _item -> projection(rest)
    end
  end

  defp after_item(tokens), do: tokens

  defp select_item([{:symbol, _p, "*", _l, _c} | rest]), do: wildcard_options(rest)
  defp select_item(tokens), do: tokens |> expression() |> item_alias()

  # `* EXCLUDE (..)`, `* EXCEPT (..)`, `* REPLACE (..)`, `* RENAME (..)` and `* ILIKE '..'`
  # are read by the engine and not by the double.
  defp wildcard_options([{:word, _p, word, _l, _c} | _rest])
       when word in ["EXCLUDE", "REPLACE", "RENAME", "ILIKE"],
       do: wildcard_option()

  defp wildcard_options([{:word, _p, "EXCEPT", _l, _c}, {:symbol, _q, "(", _l2, _c2} | _rest]),
    do: wildcard_option()

  defp wildcard_options([{:word, _p, "EXCEPT", _l, _c}, {:word, _q, word, _l2, _c2} | _rest])
       when word not in ["SELECT", "ALL", "DISTINCT"],
       do: wildcard_option()

  defp wildcard_options(tokens), do: tokens

  defp wildcard_option do
    refuse("a wildcard option (EXCLUDE, EXCEPT, REPLACE, RENAME or ILIKE) after *")
    throw(:bail)
  end

  defp item_alias([{:word, _p, "AS", _l, _c} | rest]), do: alias_name(rest)
  defp item_alias([{kind, _p, _u, _l, _c} | rest]) when kind in [:quoted, :string], do: rest

  defp item_alias([{:word, _p, upper, _l, _c} | rest] = tokens),
    do: if(upper in @alias_reserved, do: tokens, else: rest)

  defp item_alias(tokens), do: tokens

  defp alias_name([{kind, _p, _u, _l, _c} | rest]) when kind in [:word, :quoted, :string],
    do: rest

  defp alias_name(tokens), do: fail("an identifier after AS", tokens)

  # ---------------------------------------------------------------------------
  # FROM
  # ---------------------------------------------------------------------------

  defp from_clause([{:word, _p, "FROM", _l, _c} | rest]), do: from_list(rest)
  defp from_clause(tokens), do: tokens

  defp from_list(tokens) do
    case tokens |> table_factor() |> joins() do
      [{:symbol, _p, ",", _l, _c} | rest] -> from_list(rest)
      after_list -> after_list
    end
  end

  # A `JOIN` has errors of its own (`ON`, `USING`): the text is left to the
  # rest of the double.
  defp joins([{:word, _p, word, _l, _c} | _rest]) when word in @join_words, do: throw(:bail)
  defp joins(tokens), do: tokens

  defp table_factor([{:symbol, _p, "(", _l, _c}, {:word, _q, word, _l2, _c2} | _rest] = tokens)
       when word in ["SELECT", "WITH"] do
    [_open | rest] = tokens
    derived_table(rest)
  end

  defp table_factor([{:symbol, _p, "(", _l, _c}, {:word, _q, "VALUES", _l2, _c2} | _rest]),
    do: throw(:bail)

  defp table_factor([{:symbol, _p, "(", _l, _c} | rest]) do
    unless bare_name?(rest), do: refuse("a parenthesised table expression")
    rest |> table_factor() |> joins() |> close_paren() |> table_alias()
  end

  defp table_factor([{:word, _p, word, _l, _c} | _rest])
       when word in ["LATERAL", "UNNEST", "TABLE"],
       do: throw(:bail)

  defp table_factor(tokens) do
    case object_name(tokens) do
      # `FROM name(...)` calls a table function, which the engine does not have.
      [{:symbol, _p, "(", _l, _c} | args] ->
        Process.put(@table_function, true)
        args |> call_arguments() |> table_alias()

      after_name ->
        table_alias(after_name)
    end
  end

  # A derived table, and when it does not read as one the same tokens as a nested table
  # whose name is `SELECT`, which is where the engine's error is (`FROM (SELECT * FROM t`
  # is a `)` expected before the `*`).
  defp derived_table(rest) do
    rest |> query() |> close_paren() |> table_alias()
  catch
    {:syntax, _expected, _token} ->
      rest |> table_factor() |> joins() |> close_paren() |> table_alias()
  end

  # Whether the tokens after a `(` are a table's name and the `)` after it.
  defp bare_name?([{:symbol, _p, "(", _l, _c} | rest]), do: bare_name?(rest)

  defp bare_name?([{kind, _p, upper, _l, _c} | rest]) when kind in [:word, :quoted],
    do:
      upper not in ["SELECT", "WITH", "VALUES", "LATERAL", "UNNEST", "TABLE"] and
        closed?(qualified(rest))

  defp bare_name?(_tokens), do: false

  defp closed?([{:symbol, _p, ")", _l, _c} | _rest]), do: true
  defp closed?(_tokens), do: false

  defp object_name([{kind, _p, _u, _l, _c}, {:symbol, _q, ".", _l2, _c2} | rest])
       when kind in [:word, :quoted, :string],
       do: object_name(rest)

  defp object_name([{kind, _p, _u, _l, _c} | rest]) when kind in [:word, :quoted, :string],
    do: rest

  defp object_name(tokens), do: fail("identifier", tokens)

  defp table_alias([{:word, _p, "AS", _l, _c} | rest]),
    do: rest |> alias_name() |> alias_columns()

  defp table_alias([{kind, _p, _u, _l, _c} | rest]) when kind in [:quoted, :string],
    do: alias_columns(rest)

  defp table_alias([{:word, _p, upper, _l, _c} | rest] = tokens),
    do: if(upper in @alias_reserved, do: tokens, else: alias_columns(rest))

  defp table_alias(tokens), do: tokens

  # An alias may name the columns: `FROM t AS a (x, y)`.
  defp alias_columns([{:symbol, _p, "(", _l, _c} | rest]), do: column_names(rest)
  defp alias_columns(tokens), do: tokens

  defp column_names([{kind, _p, _u, _l, _c} | rest]) when kind in [:word, :quoted] do
    case rest do
      [{:symbol, _q, ",", _l2, _c2} | more] -> column_names(more)
      _end -> close_paren(rest)
    end
  end

  defp column_names(tokens), do: fail("identifier", tokens)

  # ---------------------------------------------------------------------------
  # The clauses after the select list
  # ---------------------------------------------------------------------------

  defp condition_clause([{:word, _p, keyword, _l, _c} | rest], keyword), do: expression(rest)
  defp condition_clause(tokens, _keyword), do: tokens

  defp group_by([
         {:word, _p, "GROUP", _l, _c},
         {:word, _q, "BY", _l2, _c2},
         {:word, _r, "ALL", _l3, _c3} | _rest
       ]),
       do: throw(:bail)

  defp group_by([
         {:word, _p, "GROUP", _l, _c},
         {:word, _q, "BY", _l2, _c2},
         {:word, _r, "GROUPING", _l3, _c3} | _rest
       ]),
       do: throw(:bail)

  defp group_by([{:word, _p, "GROUP", _l, _c}, {:word, _q, "BY", _l2, _c2} | rest]),
    do: group_items(rest)

  defp group_by(tokens), do: tokens

  # An empty tuple is a grouping of its own: `GROUP BY ()`.
  defp group_items(tokens) do
    case group_item(tokens) do
      [{:symbol, _p, ",", _l, _c} | rest] -> group_items(rest)
      after_list -> after_list
    end
  end

  defp group_item([{:symbol, _p, "(", _l, _c}, {:symbol, _q, ")", _l2, _c2} | rest]), do: rest
  defp group_item(tokens), do: expression(tokens)

  defp order_by([{:word, _p, "ORDER", _l, _c}, {:word, _q, "BY", _l2, _c2} | rest]),
    do: order_items(rest)

  defp order_by(tokens), do: tokens

  defp order_items(tokens) do
    case tokens |> expression() |> order_modifiers() do
      [{:symbol, _p, ",", _l, _c} | rest] -> order_items(rest)
      after_items -> after_items
    end
  end

  defp order_modifiers([{:word, _p, direction, _l, _c} | rest])
       when direction in ["ASC", "DESC"],
       do: nulls_placement(rest)

  defp order_modifiers(tokens), do: nulls_placement(tokens)

  defp nulls_placement([{:word, _p, "NULLS", _l, _c}, {:word, _q, placement, _l2, _c2} | rest])
       when placement in ["FIRST", "LAST"],
       do: rest

  defp nulls_placement(tokens), do: tokens

  # `LIMIT` and `OFFSET` in either order, each once.
  defp limit_offset([{:word, _p, "LIMIT", _l, _c} | _rest] = tokens),
    do: tokens |> limit_clause() |> offset_clause()

  defp limit_offset([{:word, _p, "OFFSET", _l, _c} | _rest] = tokens),
    do: tokens |> offset_clause() |> limit_clause()

  defp limit_offset(tokens), do: tokens

  defp limit_clause([{:word, _p, "LIMIT", _l, _c}, {:word, _q, "ALL", _l2, _c2} | rest]),
    do: rest

  defp limit_clause([{:word, _p, "LIMIT", _l, _c} | rest]) do
    case expression(rest) do
      [{:symbol, _q, ",", _l2, _c2} | more] -> expression(more)
      after_limit -> after_limit
    end
  end

  defp limit_clause(tokens), do: tokens

  # `FETCH [FIRST | NEXT] [n [PERCENT]] [ROW | ROWS] [ONLY | WITH TIES]`, after `OFFSET`.
  # The engine reads it and ignores it.
  defp fetch_clause([{:word, _p, "FETCH", _l, _c} | rest]) do
    rest
    |> fetch_word(["FIRST", "NEXT"])
    |> fetch_quantity()
    |> fetch_word(["PERCENT"])
    |> fetch_word(["ROW", "ROWS"])
    |> fetch_end()
  end

  defp fetch_clause(tokens), do: tokens

  defp fetch_word([{:word, _p, word, _l, _c} | rest] = tokens, words),
    do: if(word in words, do: rest, else: tokens)

  defp fetch_word(tokens, _words), do: tokens

  defp fetch_quantity([{:word, _p, word, _l, _c} | _rest] = tokens) when word in ["ROW", "ROWS"],
    do: tokens

  defp fetch_quantity([{kind, _p, _u, _l, _c} | rest]) when kind in [:number, :string, :literal],
    do: rest

  defp fetch_quantity([{:placeholder, _p, _u, _l, _c} | rest]), do: rest

  defp fetch_quantity([{:word, _p, word, _l, _c} | rest]) when word in ["TRUE", "FALSE", "NULL"],
    do: rest

  defp fetch_quantity([{kind, _p, _u, _l, _c} | _rest] = tokens) when kind in [:word, :quoted],
    do: fail("a concrete value", tokens)

  defp fetch_quantity(tokens), do: fail("a value", tokens)

  defp fetch_end([{:word, _p, "ONLY", _l, _c} | rest]), do: rest

  defp fetch_end([{:word, _p, "WITH", _l, _c}, {:word, _q, "TIES", _l2, _c2} | rest]), do: rest
  defp fetch_end(tokens), do: tokens

  defp offset_clause([{:word, _p, "OFFSET", _l, _c} | rest]) do
    case expression(rest) do
      [{:word, _q, rows, _l2, _c2} | more] when rows in ["ROW", "ROWS"] -> more
      after_offset -> after_offset
    end
  end

  defp offset_clause(tokens), do: tokens

  # ---------------------------------------------------------------------------
  # Expressions
  # ---------------------------------------------------------------------------

  defp expression_list(tokens) do
    case expression(tokens) do
      [{:symbol, _p, ",", _l, _c} | rest] -> expression_list(rest)
      after_list -> after_list
    end
  end

  defp expression(tokens), do: tokens |> operand() |> infix()

  # What can start an expression.
  defp operand([{kind, _p, _u, _l, _c} | rest])
       when kind in [:number, :string, :literal, :placeholder],
       do: rest

  defp operand([{:quoted, _p, _u, _l, _c} | _rest] = tokens), do: identifier(tokens)
  defp operand([{:symbol, _p, sign, _l, _c} | rest]) when sign in ["-", "+"], do: operand(rest)
  defp operand([{:symbol, _p, "(", _l, _c} | rest]), do: parenthesized(rest)
  defp operand([{:word, _p, upper, _l, _c} | _rest] = tokens), do: word_operand(upper, tokens)

  defp operand([{:symbol, _p, symbol, _l, _c} | _rest])
       when symbol in ["~", "&", "|", "^", "[", ":"],
       do: throw(:bail)

  defp operand(tokens), do: fail("an expression", tokens)

  defp parenthesized([{:word, _p, word, _l, _c} | _rest] = tokens)
       when word in ["SELECT", "WITH"],
       do: tokens |> query() |> close_paren()

  defp parenthesized(tokens), do: tokens |> expression_list() |> close_paren()

  defp close_paren([{:symbol, _p, ")", _l, _c} | rest]), do: rest
  defp close_paren(tokens), do: fail(")", tokens)

  defp word_operand(upper, _tokens) when upper in @opaque_words, do: throw(:bail)
  defp word_operand("NOT", tokens), do: attempt(tokens, &not_operand/1)
  defp word_operand("CASE", tokens), do: attempt(tokens, &case_expression/1)
  defp word_operand("INTERVAL", tokens), do: interval(tokens)
  defp word_operand("CAST", tokens), do: attempt(tokens, &cast_expression/1)

  defp word_operand(upper, [_word, {:symbol, _p, "(", _l, _c} | rest])
       when upper in @special_calls,
       do: skip_to_close(rest)

  defp word_operand(upper, [_word, {:string, _p, _u, _l, _c} | rest])
       when upper in @typed_literals,
       do: rest

  defp word_operand(_upper, tokens), do: identifier(tokens)

  # A keyword with a syntax of its own that fails to parse is an identifier
  # (or a call of that name); when that fails too, the error is the
  # keyword's.
  @spec attempt(tokens(), (tokens() -> tokens())) :: tokens()
  defp attempt(tokens, special) do
    special.(tokens)
  catch
    {:syntax, _expected, _token} = error ->
      try do
        identifier(tokens)
      catch
        {:syntax, _other_expected, _other_token} -> throw(error)
      end
  end

  # `NOT` takes the operators that bind tighter than `AND`.
  defp not_operand([_not | rest]), do: rest |> operand() |> tight_infix()

  defp case_expression([_case | rest]) do
    rest |> case_operand() |> case_branches() |> case_else() |> expect_word("END")
  end

  defp case_operand([{:word, _p, "WHEN", _l, _c} | _rest] = tokens), do: tokens
  defp case_operand(tokens), do: expression(tokens)

  defp case_branches([{:word, _p, "WHEN", _l, _c} | rest]) do
    rest |> expression() |> expect_word("THEN") |> expression() |> case_branches()
  end

  defp case_branches(tokens), do: tokens

  defp case_else([{:word, _p, "ELSE", _l, _c} | rest]), do: expression(rest)
  defp case_else(tokens), do: tokens

  defp expect_word([{:word, _p, word, _l, _c} | rest], word), do: rest
  defp expect_word(tokens, word), do: fail(word, tokens)

  # `CAST(expr AS type)`.
  defp cast_expression([_cast, {:symbol, _p, "(", _l, _c} | rest]),
    do: rest |> expression() |> expect_word("AS") |> data_type() |> close_paren()

  defp cast_expression(tokens), do: identifier(tokens)

  @type_words ~w(PRECISION WITH WITHOUT TIME ZONE VARYING UNSIGNED SIGNED)

  defp data_type([{:word, _p, _u, _l, _c} | rest]), do: rest |> type_words() |> type_arguments()
  defp data_type(tokens), do: fail("a data type name", tokens)

  defp type_words([{:word, _p, word, _l, _c} | rest]) when word in @type_words,
    do: type_words(rest)

  defp type_words(tokens), do: tokens

  # `INTERVAL '1 minute'` and `INTERVAL '1' minute`.
  defp interval([_interval, {kind, _p, _u, _l, _c} | rest]) when kind in [:string, :number] do
    case rest do
      [{:word, _q, unit, _l2, _c2} | more] when unit in @interval_units -> more
      _no_unit -> rest
    end
  end

  defp interval(_tokens), do: throw(:bail)

  # The tokens after the closing parenthesis of a call whose arguments are
  # not read here.
  defp skip_to_close(tokens) do
    case skip_to_close(tokens, 1) do
      :bail -> throw(:bail)
      after_call -> after_call
    end
  end

  defp skip_to_close([{:eof, _p, _u, _l, _c} | _rest], _depth), do: :bail
  defp skip_to_close([{:symbol, _p, ")", _l, _c} | rest], 1), do: rest

  defp skip_to_close([{:symbol, _p, ")", _l, _c} | rest], depth),
    do: skip_to_close(rest, depth - 1)

  defp skip_to_close([{:symbol, _p, "(", _l, _c} | rest], depth),
    do: skip_to_close(rest, depth + 1)

  defp skip_to_close([_token | rest], depth), do: skip_to_close(rest, depth)

  # A name, a name with qualifiers, or a call.
  defp identifier([_name | rest]) do
    case qualified(rest) do
      [{:symbol, _p, "(", _l, _c} | args] -> args |> call_arguments() |> after_call()
      after_name -> after_name
    end
  end

  defp qualified([{:symbol, _p, ".", _l, _c}, {kind, _q, _u, _l2, _c2} | rest])
       when kind in [:word, :quoted],
       do: qualified(rest)

  defp qualified([{:symbol, _p, ".", _l, _c}, {:symbol, _q, "*", _l2, _c2} | rest]),
    do: wildcard_options(rest)

  defp qualified(tokens), do: tokens

  defp call_arguments([{:symbol, _p, ")", _l, _c} | rest]), do: rest

  defp call_arguments([{:symbol, _p, "*", _l, _c}, {:symbol, _q, ")", _l2, _c2} | rest]),
    do: rest

  defp call_arguments([{:word, _p, quantifier, _l, _c} | rest])
       when quantifier in ["DISTINCT", "ALL"],
       do: argument_list(rest)

  defp call_arguments(tokens), do: argument_list(tokens)

  defp argument_list(tokens) do
    case tokens |> expression() |> argument_order() do
      [{:symbol, _p, ",", _l, _c} | rest] -> argument_list(rest)
      [{:symbol, _p, ")", _l, _c} | rest] -> rest
      [{:word, _p, word, _l, _c} | _rest] when word in ["IGNORE", "RESPECT", "ON"] -> throw(:bail)
      other -> fail(")", other)
    end
  end

  # `first_value(x ORDER BY t)`.
  defp argument_order([{:word, _p, "ORDER", _l, _c}, {:word, _q, "BY", _l2, _c2} | rest]),
    do: order_items(rest)

  defp argument_order(tokens), do: tokens

  defp after_call([{:word, _p, word, _l, _c} | _rest]) when word in @after_call_bail,
    do: throw(:bail)

  defp after_call(tokens), do: tokens

  # What can follow an operand and go on with the expression.
  defp infix(tokens) do
    case infix_step(tokens) do
      ^tokens -> tokens
      after_step -> infix(after_step)
    end
  end

  # The operators that bind tighter than `AND` and `OR`.
  defp tight_infix([{:word, _p, word, _l, _c} | _rest] = tokens) when word in @logical_words,
    do: tokens

  defp tight_infix(tokens) do
    case infix_step(tokens) do
      ^tokens -> tokens
      after_step -> tight_infix(after_step)
    end
  end

  defp infix_step([{:symbol, _p, "<=>", _l, _c} | rest]) do
    refuse("the null-safe equality operator <=>: write IS NOT DISTINCT FROM")
    operand_after_operator(rest)
  end

  defp infix_step([{:symbol, _p, symbol, _l, _c} | rest]) when symbol in @operators,
    do: operand_after_operator(rest)

  defp infix_step([{:symbol, _p, "::", _l, _c}, {:word, _q, _u, _l2, _c2} | rest]),
    do: type_arguments(rest)

  defp infix_step([{:symbol, _p, symbol, _l, _c} | _rest])
       when symbol in ["::", "[", "->", ":", "("],
       do: throw(:bail)

  defp infix_step([{:word, _p, "NOT", _l, _c}, {:word, _q, "NULL", _l2, _c2} | rest]), do: rest

  defp infix_step([{:word, _p, word, _l, _c} | rest]) when word in @logical_words,
    do: operand(rest)

  defp infix_step([{:word, _p, word, _l, _c} | rest]) when word in @predicate_words,
    do: predicate(rest, word)

  defp infix_step([{:word, _p, "NOT", _l, _c}, {:word, _q, word, _l2, _c2} | rest])
       when word in @negatable_words,
       do: predicate(rest, word)

  defp infix_step([{:word, _p, word, _l, _c} | _rest])
       when word in ["SIMILAR", "COLLATE", "AT", "ISNULL", "NOTNULL", "ESCAPE", "NULL"],
       do: throw(:bail)

  defp infix_step([{:word, _p, word, _l, _c}, {:symbol, _q, "(", _l2, _c2} | _rest])
       when word in ["ANY", "ALL", "SOME"],
       do: throw(:bail)

  defp infix_step(tokens), do: tokens

  # The arguments of a type (`DECIMAL(10, 2)`), if it has any.
  defp type_arguments([{:symbol, _p, "(", _l, _c} | rest]), do: skip_to_close(rest)
  defp type_arguments(tokens), do: tokens

  defp operand_after_operator([{:word, _p, word, _l, _c}, {:symbol, _q, "(", _l2, _c2} | _rest])
       when word in ["ANY", "ALL", "SOME"],
       do: throw(:bail)

  defp operand_after_operator(tokens), do: operand(tokens)

  defp predicate(tokens, "IS"), do: predicate_tail(tokens)
  defp predicate(tokens, "IN"), do: in_list(tokens)
  defp predicate(tokens, "BETWEEN"), do: between(tokens)
  defp predicate(tokens, _like), do: tokens |> operand() |> like_escape()

  defp like_escape([{:word, _p, "ESCAPE", _l, _c}, {:string, _q, _u, _l2, _c2} | rest]), do: rest
  defp like_escape(tokens), do: tokens

  @is_expected "[NOT] NULL | TRUE | FALSE | DISTINCT | [form] NORMALIZED FROM after IS"

  defp predicate_tail([{:word, _p, "NOT", _l, _c} | rest]), do: after_is(rest)
  defp predicate_tail(tokens), do: after_is(tokens)

  defp after_is([{:word, _p, word, _l, _c} | rest])
       when word in ["NULL", "TRUE", "FALSE", "UNKNOWN"],
       do: rest

  defp after_is([{:word, _p, "DISTINCT", _l, _c}, {:word, _q, "FROM", _l2, _c2} | rest]),
    do: operand(rest)

  defp after_is([{:word, _p, "NORMALIZED", _l, _c} | _rest]), do: throw(:bail)
  defp after_is(tokens), do: fail(@is_expected, tokens)

  defp in_list([{:symbol, _p, "(", _l, _c} | rest]) do
    case rest do
      [{:word, _q, word, _l2, _c2} | _more] when word in ["SELECT", "WITH"] ->
        rest |> subquery_or_list() |> close_paren()

      _list ->
        rest |> in_expressions() |> close_paren()
    end
  end

  defp in_list(tokens), do: fail("(", tokens)

  # A subquery, and when the tokens do not read as one a list whose first item is a column
  # called `SELECT`, which is where the engine's error is.
  defp subquery_or_list(tokens) do
    query(tokens)
  catch
    {:syntax, _expected, _token} -> in_expressions(tokens)
  end

  defp in_expressions(tokens) do
    case expression(tokens) do
      [{:symbol, _p, ",", _l, _c} | rest] -> in_expressions(rest)
      after_list -> after_list
    end
  end

  defp between(tokens),
    do: tokens |> operand() |> before_and() |> expect_word("AND") |> operand()

  # The low bound of a `BETWEEN` stops at the `AND` that belongs to it.
  defp before_and([{:word, _p, "AND", _l, _c} | _rest] = tokens), do: tokens

  defp before_and([{:symbol, _p, symbol, _l, _c} | rest]) when symbol in @bound_operators,
    do: rest |> operand() |> before_and()

  defp before_and(tokens), do: tokens
end
