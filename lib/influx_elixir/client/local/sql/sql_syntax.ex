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

  alias InfluxElixir.Client.Local.{
    SQLDml,
    SQLDmlType,
    SQLError,
    SQLInterval,
    SQLLiteral,
    SQLNamedArg,
    SQLStatement,
    SQLTokenizer
  }

  @top {__MODULE__, :top}
  @refusal {__MODULE__, :refusal}
  @planner {__MODULE__, :planner}
  @into {__MODULE__, :into}
  @depth {__MODULE__, :depth}
  @set_operation {__MODULE__, :set_operation}
  @named {__MODULE__, :named}
  @unknown_call {__MODULE__, :unknown_call}
  @arrow {__MODULE__, :arrow}
  @recursion {__MODULE__, :recursion}
  @swallow {__MODULE__, :swallow}
  @dml_read {__MODULE__, :dml_read}

  # The engine's parser stops at 50 nested calls of its recursive descent (sqlparser-rs's
  # `RecursionCounter`, verified on 3.10.1): `parse_statement`, `parse_query` and every
  # `parse_subexpr` count one while they run, so the 51st nested one fails.
  @recursion_limit 50

  # The precedences the parser reads a prefix operator's and a `BETWEEN` bound's operand with.
  @unary_precedence 40
  @not_precedence 15
  @between_precedence 20

  # The words that are operators, with their precedence (sqlparser `Precedence`).
  @word_precedence %{
    "OR" => 5,
    "AND" => 10,
    "IS" => 17,
    "LIKE" => 19,
    "ILIKE" => 19,
    "SIMILAR" => 19,
    "IN" => 20,
    "BETWEEN" => 20,
    "XOR" => 24,
    "DIV" => 40,
    "COLLATE" => 50,
    "AT" => 50,
    "ISNULL" => 50,
    "NOTNULL" => 50,
    "ESCAPE" => 50,
    "NULL" => 50
  }

  # How far the double has verified the engine to answer what it cannot count exactly: a
  # keyword that falls back to a name when its own syntax fails (`CASE`, `CAST`, `NOT (`)
  # swallows the limit's error and parses the statement again at every level, so the engine's
  # time grows with the depth and its answer past the limit was not probed. Core answered
  # twenty of each, nested; the double refuses deeper.
  @swallow_limit 20

  # Core answered subqueries nested twenty-two deep (and was slow at twenty-three).
  @subquery_limit 23

  # A nest the double reads no further (the arguments of `EXTRACT`, a statement it does not
  # parse) is bounded by its parentheses and its run of prefix operators: each costs the
  # engine at least one level, so the double refuses past a bound well under the limit.
  @unread_limit 40

  @typep token :: SQLTokenizer.token()
  @typep tokens :: SQLTokenizer.tokens()

  # Words that are not taken as the alias of a select item, nor begin one (`LEFT`, `RIGHT`,
  # `ON` and `FORMAT` are names there; the join words only follow a table).
  @column_reserved ~w(FROM INTO WITH EXPLAIN ANALYZE SELECT WHERE GROUP SORT HAVING ORDER TOP
    LATERAL VIEW LIMIT OFFSET FETCH UNION EXCEPT INTERSECT MINUS CLUSTER DISTRIBUTE RETURNING
    END)

  # Words that are not taken as the alias of a table.
  @table_reserved ~w(FROM WITH EXPLAIN ANALYZE SELECT WHERE GROUP SORT HAVING ORDER PIVOT
    UNPIVOT TOP LATERAL VIEW LIMIT OFFSET FETCH UNION EXCEPT INTERSECT MINUS ON JOIN INNER CROSS
    FULL LEFT RIGHT NATURAL USING CLUSTER DISTRIBUTE ANTI SEMI RETURNING ASOF OUTER SET
    QUALIFY WINDOW END FOR PARTITION PREWHERE SETTINGS FORMAT START CONNECT)

  # Words with a clause of their own after a query, whose errors this grammar does not read.
  @own_syntax ~w(PIVOT UNPIVOT JOIN INNER CROSS FULL LEFT RIGHT NATURAL ANTI SEMI ASOF OUTER
    QUALIFY WINDOW FOR PARTITION PREWHERE SETTINGS FORMAT START CONNECT)

  # Words with a syntax of their own that this grammar does not read, and
  # words read as a call whose arguments have one.
  @opaque_words ~w(EXISTS ARRAY STRUCT MAP CONVERT MATCH PRIOR LISTAGG)
  @special_calls ~w(TRY_CAST SAFE_CAST EXTRACT CEIL FLOOR POSITION SUBSTRING SUBSTR OVERLAY TRIM)
  @typed_literals ~w(DATE TIME TIMESTAMP TIMESTAMPTZ DATETIME)
  @niladic ~w(CURRENT_TIME CURRENT_DATE CURRENT_TIMESTAMP)
  @after_call_bail ~w(FILTER OVER WITHIN IGNORE RESPECT)
  @own_words ~w(SELECT ALL DISTINCT TRUE FALSE NULL AS INTERVAL TO IS NOT AND OR YEAR YEARS MONTH
    MONTHS WEEK WEEKS DAY DAYS HOUR HOURS MINUTE MINUTES SECOND SECONDS MILLISECOND MILLISECONDS
    MICROSECOND MICROSECONDS NANOSECOND NANOSECONDS)
  @interval_units ~w(YEAR YEARS MONTH MONTHS WEEK WEEKS DAY DAYS HOUR HOURS MINUTE MINUTES SECOND
    SECONDS MILLISECOND MILLISECONDS MICROSECOND MICROSECONDS NANOSECOND NANOSECONDS)
  @operators ~w(= == <=> <> != < > <= >= + - * / % || ~ !~ ~* !~* & | ^ << >> ~~ ~~* !~~ !~~* //)
  @predicate_words ~w(IS IN BETWEEN LIKE ILIKE)
  @negatable_words ~w(IN BETWEEN LIKE ILIKE)
  @join_words ~w(JOIN INNER LEFT RIGHT FULL CROSS NATURAL OUTER STRAIGHT_JOIN)
  @logical_words ~w(AND OR XOR)
  @bound_operators ~w(+ - * / % ||)
  @table_function {__MODULE__, :table_function}
  @several {__MODULE__, :several}
  @flags [
    @several,
    @table_function,
    @top,
    @refusal,
    @planner,
    @into,
    @depth,
    @set_operation,
    @named,
    @unknown_call,
    @arrow,
    @recursion,
    @swallow,
    @dml_read
  ]

  @doc """
  Runs `fun`, which checks a query the double builds from an operand of an `INSERT`, `UPDATE` or
  `DELETE` (`SELECT <operand>`), with one level of the parser's recursion credited: the
  statement it stands for was counted whole (`nesting_verdict/1`), and the operand costs it
  one level less than the query built from it (an `UPDATE` has no query of its own).
  """
  @spec credited((-> result)) :: result when result: term()
  def credited(fun) do
    Process.put(@recursion, -1)

    try do
      fun.()
    after
      Process.delete(@recursion)
    end
  end

  @doc """
  `:ok` when the text reads as a statement (or this grammar cannot say), else
  the engine's parser error.
  """
  @spec check(binary(), boolean()) :: :ok | {:error, SQLError.t()}
  def check(sql, several? \\ false) do
    case early_verdict(sql) do
      {:error, _error} = error -> error
      nil -> check_tokens(SQLTokenizer.scan(sql), several?, sql)
    end
  end

  # A statement nested past the parser's limit is refused from the start of its text: the
  # first windows of it are read (cut at a blank, the last tokens left out, so that nothing
  # read stands near the cut), and the error the parser gives while still inside the window is
  # the error of the whole text, which the double need not tokenize (a text a hundred
  # kilobytes deep holds a hundred thousand tokens). Only a text whose later bytes are all
  # ones the tokenizer reads is judged so: a character it does not read comes first on the
  # engine, which tokenizes before it parses.
  @windows [8_192, 65_536]
  @cut_tokens 16

  @doc """
  The parser's refusal of an `INSERT`, `UPDATE` or `DELETE` nested past its recursion limit of 50,
  or `nil`. The expressions of the statement are counted as a query's are (the values of an
  `INSERT`, its query, the values and the `WHERE` of an `UPDATE`, the `WHERE` of a `DELETE`);
  a statement of a shape this grammar does not read is bounded by the parentheses and prefix
  operators it holds, well under the limit.
  """
  @spec nesting_verdict(binary()) :: SQLError.t() | nil
  def nesting_verdict(sql) do
    result =
      case SQLTokenizer.scan(sql) do
        {:ok, tokens} -> dml_verdict(tokens)
        _unread -> text_verdict(sql)
      end

    case result do
      {:error, error} -> error
      :ok -> nil
    end
  end

  @doc """
  The parser's refusal of a long, single query nested past its recursion limit, read from the
  first bytes of the text, or `nil` for any other text (which the whole check reads).
  """
  @spec deep_refusal(binary()) :: SQLError.t() | nil
  def deep_refusal(sql) when is_binary(sql) do
    with true <- single_statement?(sql),
         {:error, error} <- early_verdict(sql) do
      error
    else
      _read_whole -> nil
    end
  end

  # One statement: no `;`, or only blanks after the first one.
  defp single_statement?(sql) do
    case :binary.match(sql, ";") do
      :nomatch -> true
      {at, 1} -> String.trim(binary_part(sql, at + 1, byte_size(sql) - at - 1)) == ""
    end
  end

  @spec early_verdict(binary()) :: {:error, SQLError.t()} | nil
  defp early_verdict(sql) do
    if byte_size(sql) > hd(@windows) and query_start?(sql) and plain_text?(sql) do
      Enum.find_value(@windows, fn window ->
        if window < byte_size(sql), do: window_verdict(sql, window)
      end)
    end
  end

  defp query_start?(sql) do
    trimmed = String.trim_leading(sql)
    head = binary_part(trimmed, 0, min(6, byte_size(trimmed)))
    String.starts_with?(String.upcase(head), ["SELECT", "WITH", "("])
  end

  # Whether every byte of the text is one that no tokenizer error can be about: no quote,
  # comment opener, brace or byte outside ASCII.
  defp plain_text?(<<byte, rest::binary>>)
       when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or
              byte in ~c" \t\n\r(),.+-*/%=<>_;!|:$",
       do: plain_text?(rest)

  defp plain_text?(<<>>), do: true
  defp plain_text?(_other), do: false

  defp window_verdict(sql, window) do
    prefix = binary_part(sql, 0, window)

    with {at, _length} <- :binary.match(String.reverse(prefix), [" ", "("]),
         {:ok, tokens} <- SQLTokenizer.scan(binary_part(prefix, 0, window - at)),
         {kept, [eof]} <- Enum.split(tokens, -1),
         true <- length(kept) > @cut_tokens do
      Process.put(@several, false)
      {kept, _dropped} = Enum.split(kept, -@cut_tokens)

      try do
        case read(kept ++ [eof]) do
          {:error, %{body: "SQL error: RecursionLimitExceeded" <> _rest}} = error ->
            error

          {:error, %{body: "Client.Local: unsupported SQL (statement nested" <> _rest}} = error ->
            error

          _other ->
            nil
        end
      after
        Enum.each(@flags, &Process.delete/1)
      end
    else
      _unread -> nil
    end
  end

  # The same over a text that is already tokenized.
  @spec check_tokens(SQLTokenizer.result(), boolean(), binary()) ::
          :ok | {:error, SQLError.t()}
  defp check_tokens(tokenized, several?, text) do
    Process.put(@several, several?)

    case tokenized do
      {:ok, tokens} ->
        tokens |> read() |> flagged(tokens)

      :bail ->
        text_verdict(text)

      {:unread, char} ->
        {:error,
         SQLError.refusal(
           "the character #{inspect(char)} in a name or outside quotes: the engine's parser error " <>
             "for it is not modelled"
         )}
    end
  after
    Enum.each(@flags, &Process.delete/1)
  end

  @doc """
  `:ok`, or the engine's parser error for the first of the statements of a text
  that does not read, each read at the line and column it stands at in the whole
  text.
  """
  @spec check_statements(binary()) :: :ok | {:error, SQLError.t()}
  def check_statements(sql) do
    pieces = SQLTokenizer.split(sql)
    several? = match?([_one, _two | _more], pieces)

    case if(several?, do: nil, else: early_verdict(sql)) do
      {:error, _error} = error -> error
      nil -> check_pieces(pieces, sql, several?)
    end
  end

  @spec check_pieces([{non_neg_integer(), binary()}], binary(), boolean()) ::
          :ok | {:error, SQLError.t()}
  defp check_pieces(pieces, sql, several?) do
    pieces
    |> Enum.reduce_while(false, fn {offset, piece}, unread? ->
      positioned = SQLTokenizer.blank(binary_part(sql, 0, offset)) <> piece
      tokenized = SQLTokenizer.scan(positioned)

      case statement_verdict(positioned, tokenized, several?) do
        :ok -> {:cont, unread? or tokenized == :bail}
        {:error, _error} = error -> {:halt, {:failed, error, unread?}}
      end
    end)
    |> case do
      {:failed, {:error, error}, true} -> {:error, after_unread(error)}
      {:failed, error, false} -> error
      _read -> :ok
    end
  end

  # The error of a statement after one the double cannot read (a `{` or `#` its tokenizer does
  # not know): the engine stops at the first statement that does not read, which may be that
  # one, so the later error is not the engine's.
  @spec after_unread(SQLError.t()) :: SQLError.t()
  defp after_unread(%{body: "SQL error: ParserError" <> _rest}) do
    SQLError.refusal(
      "a parser error in a statement after one the double cannot read: the engine reports " <>
        "the first statement that does not read"
    )
  end

  defp after_unread(error), do: error

  @spec statement_verdict(binary(), SQLTokenizer.result(), boolean()) ::
          :ok | {:error, SQLError.t()}
  defp statement_verdict(positioned, tokenized, several?) do
    case first_token_error(positioned, tokenized) do
      nil -> check_tokens(tokenized, several?, positioned)
      error -> {:error, error}
    end
  end

  # The parser's error for a statement that starts with no statement, or is a statement word
  # with nothing after it (`DELETE`, `USE`); the other answers of a bare word (`BEGIN`, `END`)
  # are the planner's, which a text of several statements never reaches.
  @spec first_token_error(binary(), SQLTokenizer.result()) :: SQLError.t() | nil
  defp first_token_error(positioned, tokenized) do
    # A `;` ends nothing the parser needs to read: it is the token it finds where the
    # statement has no more (verified: `SELECT ; FROM t` is "found: ;" at the `;`).
    statement = String.replace_suffix(positioned, ";", "")

    SQLStatement.parser_error(statement, without_semicolon(statement != positioned, tokenized)) ||
      parse_only(SQLStatement.bare_error(positioned))
  end

  # The tokens of the statement without its closing `;`, from the tokens of the text with it
  # (the end of the text then stands where the `;` did), so that a piece is tokenized once.
  @spec without_semicolon(boolean(), SQLTokenizer.result()) :: SQLTokenizer.result() | nil
  defp without_semicolon(false, tokenized), do: tokenized

  defp without_semicolon(true, {:ok, tokens}) do
    case Enum.split(tokens, -2) do
      {before, [{:symbol, ";", _upper, line, col}, {:eof, printed, upper, _l, _c}]} ->
        {:ok, before ++ [{:eof, printed, upper, line, col}]}

      _other ->
        nil
    end
  end

  defp without_semicolon(true, other), do: other

  defp parse_only(%{body: "SQL error: ParserError" <> _rest} = error), do: error
  defp parse_only(_other), do: nil

  # `0x1F` is a binary value to the engine, which the double refuses by name once the text
  # reads.
  @spec read(tokens()) :: :ok | {:error, SQLError.t()}
  defp read(tokens) do
    if Enum.any?(tokens, &SQLTokenizer.hex?/1),
      do:
        refuse(
          "a hexadecimal number (0x...) is a binary value on the engine, " <>
            "which this double does not model"
        )

    with :ok <- statement(tokens), do: unread_verdict(tokens)
  end

  # A query is counted as the parser counts it, and so is a statement that changes data of a
  # shape read whole (`dml_recursion/1`); any other statement is not read here, so its nesting is
  # bounded by its parentheses and prefix operators.
  @spec unread_verdict(tokens()) :: :ok | {:error, SQLError.t()}
  defp unread_verdict([{:word, _p, word, _l, _c} | _rest]) when word in ["SELECT", "WITH"],
    do: :ok

  defp unread_verdict([{:symbol, _p, "(", _l, _c} | _rest]), do: :ok

  defp unread_verdict(tokens) do
    if Process.get(@dml_read), do: :ok, else: bail_verdict(tokens)
  end

  # A statement that changes data, read whole by the grammar below: counted, so that it is
  # refused at the engine's depth and no sooner. One that is not read whole is bounded by its
  # parentheses.
  @spec dml_verdict(tokens()) :: :ok | {:error, SQLError.t()}
  defp dml_verdict(tokens) do
    case dml_recursion(tokens) do
      {:error, _error} = error -> error
      :read -> :ok
      :unread -> bail_verdict(tokens)
    end
  end

  # The reading is isolated: the flags it sets (a refusal, a planner note) are the query
  # reader's, and a statement that changes data has none of them.
  @spec dml_recursion(tokens()) :: :read | :unread | {:error, SQLError.t()}
  defp dml_recursion(tokens) do
    saved = Enum.map(@flags, &{&1, Process.get(&1)})

    try do
      counted(fn -> tokens |> dml_expressions() |> dml_end() end)
      :read
    catch
      :recursion -> {:error, SQLError.recursion()}
      {:fail, error} -> {:error, error}
      {:syntax, _expected, _token} -> :unread
      :bail -> :unread
    after
      Enum.each(saved, fn
        {flag, nil} -> Process.delete(flag)
        {flag, value} -> Process.put(flag, value)
      end)
    end
  end

  # What the parser reads of each statement, as far as its recursion goes: `parse_statement`
  # (the `counted` above), `parse_query` for what an `INSERT` inserts, and a `parse_subexpr` for
  # every expression, as in a query.
  @spec dml_expressions(tokens()) :: tokens()
  defp dml_expressions([{:word, _p, "INSERT", _l, _c}, {:word, _q, "INTO", _l2, _c2} | rest]),
    do: rest |> object_name() |> insert_columns() |> insert_body()

  defp dml_expressions([{:word, _p, "UPDATE", _l, _c} | rest]),
    do: rest |> object_name() |> update_alias() |> update_set() |> dml_where()

  defp dml_expressions([{:word, _p, "DELETE", _l, _c}, {:word, _q, "FROM", _l2, _c2} | rest]),
    do: rest |> object_name() |> dml_where()

  defp dml_expressions(_tokens), do: throw(:bail)

  defp dml_end([{:eof, _p, _u, _l, _c}] = tokens), do: tokens
  defp dml_end([{:symbol, _p, ";", _l, _c}, {:eof, _q, _u, _l2, _c2}] = tokens), do: tokens
  defp dml_end(_tokens), do: throw(:bail)

  defp insert_columns([{:symbol, _p, "(", _l, _c}, {:word, _q, word, _l2, _c2} | _rest] = tokens)
       when word in ["SELECT", "WITH", "VALUES"],
       do: tokens

  defp insert_columns([{:symbol, _p, "(", _l, _c} | rest]), do: column_names(rest)
  defp insert_columns(tokens), do: tokens

  # `VALUES` is a query body of its own, read by `parse_query`; each cell is a `parse_expr`.
  defp insert_body([{:word, _p, "VALUES", _l, _c} | rest]) do
    counted(fn -> rest |> value_rows() |> order_by() |> limit_offset() |> fetch_clause() end)
  end

  defp insert_body([{:word, _p, word, _l, _c} | _rest] = tokens) when word in ["SELECT", "WITH"],
    do: query(tokens)

  defp insert_body([{:symbol, _p, "(", _l, _c} | _rest] = tokens), do: query(tokens)
  defp insert_body(_tokens), do: throw(:bail)

  defp value_rows([{:symbol, _p, "(", _l, _c} | rest]) do
    case rest |> expression_list() |> close_paren() do
      [{:symbol, _q, ",", _l2, _c2} | more] -> value_rows(more)
      after_rows -> after_rows
    end
  end

  defp value_rows(tokens), do: fail("(", tokens)

  defp update_alias([{:word, _p, "SET", _l, _c} | _rest] = tokens), do: tokens

  defp update_alias([{:word, _p, "AS", _l, _c}, {kind, _q, _u, _l2, _c2} | rest])
       when kind in [:word, :quoted],
       do: rest

  defp update_alias([{kind, _p, _u, _l, _c} | rest]) when kind in [:word, :quoted], do: rest
  defp update_alias(tokens), do: tokens

  defp update_set([{:word, _p, "SET", _l, _c} | rest]), do: assignments(rest)
  defp update_set(_tokens), do: throw(:bail)

  defp assignments(tokens) do
    case tokens |> object_name() |> assignment_value() do
      [{:symbol, _p, ",", _l, _c} | rest] -> assignments(rest)
      after_assignments -> after_assignments
    end
  end

  defp assignment_value([{:symbol, _p, "=", _l, _c} | rest]), do: expression(rest)
  defp assignment_value(_tokens), do: throw(:bail)

  defp dml_where([{:word, _p, "WHERE", _l, _c} | rest]), do: expression(rest)
  defp dml_where(tokens), do: tokens

  # A statement the parse of which was left half-way is bounded the same way.
  @spec bail_verdict(tokens()) :: :ok | {:error, SQLError.t()}
  defp bail_verdict(tokens) do
    if deep?(tokens, 0, 0), do: {:error, nesting_refusal()}, else: :ok
  end

  defp deep?([], _depth, _run), do: false
  defp deep?(_tokens, depth, run) when depth > @unread_limit or run > @unread_limit, do: true

  defp deep?([{:symbol, _p, "(", _l, _c} | rest], depth, _run), do: deep?(rest, depth + 1, 0)

  defp deep?([{:symbol, _p, ")", _l, _c} | rest], depth, _run),
    do: deep?(rest, max(depth - 1, 0), 0)

  defp deep?([{:symbol, _p, sign, _l, _c} | rest], depth, run) when sign in ["-", "+"],
    do: deep?(rest, depth, run + 1)

  defp deep?([{:word, _p, "NOT", _l, _c} | rest], depth, run), do: deep?(rest, depth, run + 1)
  defp deep?([_token | rest], depth, _run), do: deep?(rest, depth, 0)

  # The same over a text that could not be tokenized: its parentheses, quoted or not.
  @spec text_verdict(binary()) :: :ok | {:error, SQLError.t()}
  defp text_verdict(text), do: if(deep_text?(text, 0), do: {:error, nesting_refusal()}, else: :ok)

  defp deep_text?(_text, depth) when depth > @unread_limit, do: true
  defp deep_text?(<<"(", rest::binary>>, depth), do: deep_text?(rest, depth + 1)
  defp deep_text?(<<")", rest::binary>>, depth), do: deep_text?(rest, max(depth - 1, 0))
  defp deep_text?(<<_byte, rest::binary>>, depth), do: deep_text?(rest, depth)
  defp deep_text?(<<>>, _depth), do: false

  @spec nesting_refusal() :: SQLError.t()
  defp nesting_refusal do
    SQLError.refusal(
      "unsupported SQL (statement nested deeper than Core was verified to answer): the " <>
        "engine's parser stops at 50 levels of recursion"
    )
  end

  # What a text that reads is still answered with: the engine's `TOP` is no feature of its
  # planner (405), and a spelling the double cannot read is refused by name.
  @spec flagged(:ok | {:error, SQLError.t()}, tokens()) :: :ok | {:error, SQLError.t()}
  defp flagged(:ok, tokens) do
    cond do
      Process.get(@top) ->
        {:error, %{status: 405, body: "This feature is not implemented: TOP"}}

      reason = Process.get(@refusal) ->
        {:error, SQLError.refusal(reason)}

      named = Process.get(@named) ->
        {:error, named_verdict(named, tokens)}

      message = Process.get(@arrow) ->
        {:error, arrow_verdict(message, tokens)}

      Process.get(@table_function) ->
        {:error, SQLError.refusal("a table function in FROM: the engine has none")}

      message = Process.get(@planner) ->
        unsupported(message, tokens)

      Process.get(@into) ->
        into_verdict(tokens)

      true ->
        :ok
    end
  end

  defp flagged(error, _tokens), do: error

  # A call with a named argument is the planner's error for the function, whatever its
  # arguments hold: the double answers it for a text that names no table and no column,
  # where nothing else can come before it.
  # An interval literal that overflows is an error of the engine's parser of intervals, found
  # as the planner reads the literal: the double answers it for a text that names no table and no
  # column, where nothing else can come before it.
  @spec arrow_verdict(binary(), tokens()) :: map()
  defp arrow_verdict(message, tokens) do
    if constant?(tokens, true),
      do: %{status: 500, body: "Arrow error: " <> message},
      else:
        SQLError.refusal(
          "an INTERVAL that does not fit, in a text that names columns or tables: which " <>
            "error the engine gives first depends on the clause"
        )
  end

  @spec named_verdict({token(), binary() | nil}, tokens()) :: SQLError.t()
  defp named_verdict({_name, unknown}, _tokens) when is_binary(unknown),
    do: SQLNamedArg.unknown_before(unknown)

  defp named_verdict({{:word, printed, _upper, _l, _c}, nil}, tokens) do
    if constant?(tokens, true),
      do: SQLNamedArg.error(printed),
      else: SQLNamedArg.with_names()
  end

  defp named_verdict({{_kind, printed, _upper, _l, _c}, nil}, _tokens),
    do: SQLNamedArg.unknown_before(printed)

  # The planner's refusal of a construct the parser read. It comes after the planner has
  # found the tables and columns of the text, so it is the engine's answer only where the
  # text names none; elsewhere which error comes first depends on the clause.
  @spec unsupported(binary(), tokens()) :: {:error, SQLError.t() | map()}
  defp unsupported(message, tokens) do
    if constant?(tokens),
      do: {:error, %{status: 405, body: "This feature is not implemented: " <> message}},
      else:
        {:error,
         SQLError.refusal(
           "#{message} in a text that names columns or tables: which error the engine " <>
             "gives first depends on the clause"
         )}
  end

  # Whether the text names no table, column or function: its words are the statement's own
  # (or follow `AS`, which names an item whatever the word is).
  @spec constant?(tokens(), boolean()) :: boolean()
  defp constant?(tokens, calls? \\ false) do
    tokens
    |> Enum.zip([nil | tokens])
    |> Enum.zip(Enum.drop(tokens, 1) ++ [nil])
    |> Enum.zip(Enum.drop(tokens, 2) ++ [nil, nil])
    |> Enum.all?(fn {{{token, previous}, next}, after_next} ->
      constant_token?(token, previous, {next, after_next}) or
        (calls? and called_or_named?(token, next))
    end)
  end

  # A function's name, or the name of an argument, is no table or column.
  @spec called_or_named?(token(), token() | nil) :: boolean()
  defp called_or_named?({:word, _printed, _upper, _line, _col}, next),
    do: match?({:symbol, "(", _u, _l, _c}, next) or match?({:symbol, "=>", _u, _l, _c}, next)

  defp called_or_named?(_token, _next), do: false

  # A word after `AS` or `TABLE` is named by the statement, and so is the name of a common
  # table (`name AS (`) and the keyword `WITH` that starts them.
  @spec constant_token?(token(), token() | nil, {token() | nil, token() | nil}) :: boolean()
  defp constant_token?({:word, _printed, upper, _line, _col}, previous, {next, after_next}) do
    match?({:word, _p, kind, _l, _c} when kind in ["AS", "TABLE"], previous) or
      upper in ["WITH", "TABLE" | @own_words] or
      (match?({:word, _q, "AS", _l2, _c2}, next) and
         match?({:symbol, _s, "(", _l3, _c3}, after_next))
  end

  defp constant_token?(_token, _previous, _following), do: true

  # `SELECT ... INTO name` is the engine's `CREATE TABLE AS`, which it refuses once the
  # select has planned. The double plans the select without the clause (`SQLRewrite`) and
  # answers the refusal, for a plain top-level `SELECT`; any other `INTO` is refused by name.
  @spec into_verdict(tokens()) :: :ok | {:error, SQLError.t()}
  defp into_verdict([{:word, _printed, "SELECT", _line, _col} | _rest]) do
    if Process.get(@into) == :plain and not Process.get(@set_operation, false),
      do: :ok,
      else: {:error, SQLError.refusal("an INTO clause outside a plain SELECT")}
  end

  defp into_verdict(_tokens),
    do: {:error, SQLError.refusal("an INTO clause outside a plain SELECT")}

  @spec refuse(binary()) :: :ok
  defp refuse(reason) do
    Process.put(@refusal, reason)
    :ok
  end

  # ---------------------------------------------------------------------------
  # The statement
  # ---------------------------------------------------------------------------

  @spec statement(tokens()) :: :ok | {:error, SQLError.t()}
  defp statement([{:word, _printed, first, _line, _col} | _rest] = tokens)
       when first in ["SELECT", "WITH"],
       do: read_query(tokens)

  defp statement([{:symbol, _printed, "(", _line, _col} | _rest] = tokens),
    do: read_query(tokens)

  # A statement that changes data is read whole by the DML reader, which has the parser's error
  # for it: where the text holds several statements (the parser reads each whole, the first with
  # an error is the answer) the reader is asked here; a statement alone is read by the reader when
  # it is planned. The checks below only add what that reader does not say.
  defp statement([{:word, _p, word, _l, _c} | _rest] = tokens)
       when word in ["INSERT", "UPDATE", "DELETE"] do
    case Process.get(@several, false) && SQLDml.parse_error(tokens) do
      error when error in [nil, false] -> counted_statement(tokens)
      error -> {:error, error}
    end
  end

  defp statement(_tokens), do: :ok

  @spec counted_statement(tokens()) :: :ok | {:error, SQLError.t()}
  defp counted_statement(tokens) do
    case dml_recursion(tokens) do
      {:error, _error} = error ->
        error

      read ->
        if read == :read, do: Process.put(@dml_read, true)
        dml_statement(tokens)
    end
  end

  @spec dml_statement(tokens()) :: :ok | {:error, SQLError.t()}
  defp dml_statement([{:word, _p, "DELETE", _l, _c}, {:word, _q, "FROM", _l2, _c2} | rest]) do
    rest |> delete_target() |> delete_where()
    :ok
  catch
    {:syntax, expected, token} -> {:error, parser_error(expected, token)}
    :bail -> :ok
  end

  defp dml_statement([{:word, _p, "INSERT", _l, _c}, {:word, _q, "INTO", _l2, _c2} | rest]) do
    rest |> object_name() |> insert_source()
    :ok
  catch
    {:syntax, expected, token} -> {:error, parser_error(expected, token)}
  end

  # `UPDATE t SET` wants the column it assigns: a `;` or the end of the text is not one.
  defp dml_statement([{:word, _p, "UPDATE", _l, _c} | rest]) do
    case object_name(rest) do
      [{:word, _q, "SET", _l2, _c2}, {kind, _r, _u, _l3, _c3} = token | _more]
      when kind == :eof or (kind == :symbol and elem(token, 1) == ";") ->
        {:error, parser_error("identifier", token)}

      _read ->
        :ok
    end
  catch
    {:syntax, expected, token} -> {:error, parser_error(expected, token)}
  end

  defp dml_statement(_tokens), do: :ok

  # What an `INSERT` inserts is a query: with the text ended there is none to read. (What
  # follows otherwise is read by the DML reader, with the rest of the statement.)
  @spec insert_source(tokens()) :: tokens()
  defp insert_source([{:eof, _p, _u, _l, _c} | _rest] = tokens),
    do: fail("SELECT, VALUES, or a subquery in the query body", tokens)

  defp insert_source([{:symbol, _p, ";", _l, _c} | _rest] = tokens),
    do: fail("SELECT, VALUES, or a subquery in the query body", tokens)

  defp insert_source(tokens), do: tokens

  # The name a `DELETE FROM` deletes from; in parentheses it is a table name again (the
  # planner refuses the statement whatever it deletes from) or a subquery, which the engine's
  # error prints as the statement it parsed (verified), which the double does not.
  @spec delete_target(tokens()) :: tokens()
  defp delete_target([{:symbol, _p, "(", _l, _c} | rest]) do
    case rest do
      [{:word, _q, word, _l2, _c2} | _more] when word in ["SELECT", "WITH"] ->
        refuse("a DELETE FROM a subquery: the engine's error for it prints the parsed query")
        throw(:bail)

      _name ->
        rest |> object_name() |> close_paren()
    end
  end

  defp delete_target(tokens), do: object_name(tokens)

  # `WHERE` wants an expression: with the statement ended there is none. (The expression
  # itself is read by the DML reader, which knows the engine's types.)
  @spec delete_where(tokens()) :: tokens()
  defp delete_where([{:word, _p, "WHERE", _l, _c}, {:eof, _q, _u, _l2, _c2} | _rest] = tokens),
    do: fail("an expression", tl(tokens))

  defp delete_where(
         [{:word, _p, "WHERE", _l, _c}, {:symbol, _q, ";", _l2, _c2} | _rest] = tokens
       ),
       do: fail("an expression", tl(tokens))

  defp delete_where(tokens), do: tokens

  @spec read_query(tokens()) :: :ok | {:error, SQLError.t()}
  defp read_query(tokens) do
    case counted(fn -> query(tokens) end) do
      [{:eof, _printed, _upper, _line, _col}] -> :ok
      [{:symbol, _printed, ";", _line, _col}, {:eof, _p, _u, _l, _c}] -> :ok
      [{:word, _printed, upper, _line, _col} | _rest] when upper in @own_syntax -> :ok
      [token | _rest] -> {:error, parser_error("end of statement", token)}
    end
  catch
    {:syntax, expected, token} -> {:error, parser_error(expected, token)}
    {:fail, error} -> {:error, error}
    :recursion -> {:error, SQLError.recursion()}
    :bail -> bail_verdict(tokens)
  end

  # Runs `fun` one level deeper in the engine's recursion: `parse_statement`, `parse_query` and
  # `parse_subexpr` each decrement the counter while they run, and the call that finds it at zero
  # fails. Where a keyword that falls back to a name is open the error is the engine's swallowed
  # one, whose answer the double did not probe, so it refuses by name there.
  @spec counted((-> result)) :: result when result: tokens()
  defp counted(fun) do
    depth = Process.get(@recursion, 0)
    if depth >= @recursion_limit, do: overflow()
    Process.put(@recursion, depth + 1)

    try do
      fun.()
    after
      Process.put(@recursion, depth)
    end
  end

  @spec overflow() :: no_return()
  defp overflow do
    if Process.get(@swallow, 0) > 0,
      do: throw({:fail, nesting_refusal()}),
      else: throw(:recursion)
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
    depth = Process.get(@depth, 0)
    if depth >= @subquery_limit, do: throw({:fail, nesting_refusal()})
    Process.put(@depth, depth + 1)

    try do
      counted(fn ->
        tokens
        |> with_clause()
        |> select_term()
        |> set_operations()
        |> order_by()
        |> limit_offset()
        |> fetch_clause()
      end)
    after
      Process.put(@depth, depth)
    end
  end

  # The engine reads an `INSERT`, `UPDATE` or `DELETE` after a `WITH` as the body of the query and
  # answers that it is not implemented, printing the statement as it parsed it (verified), which
  # the double does not.
  defp with_clause([{:word, _p, "WITH", _l, _c} | rest]) do
    case common_tables(rest) do
      [{:word, _q, word, _l2, _c2} | _more] when word in ["INSERT", "UPDATE", "DELETE"] ->
        refuse(
          "#{word} after a WITH clause: the engine's error for it prints the statement as it " <>
            "parsed it"
        )

        throw(:bail)

      tokens ->
        tokens
    end
  end

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

  defp common_tables([{kind, _p, _u, _l, _c}, {:word, _q, "AS", _l2, _c2} | rest])
       when kind in [:word, :quoted],
       do: fail("(", rest)

  defp common_tables([{kind, _p, _u, _l, _c} | _rest] = tokens) when kind in [:word, :quoted],
    do: fail("AS", tl(tokens))

  defp common_tables(tokens), do: fail("identifier", tokens)

  defp select_term([{:symbol, _p, "(", _l, _c} | rest]), do: rest |> query() |> close_paren()
  defp select_term([{:word, _p, "SELECT", _l, _c} | rest]), do: select_core(rest)

  defp select_term([{:word, _p, "FROM", _l, _c} | _rest]) do
    refuse("a query that begins with FROM: the engine reads it, this double does not")
    throw(:bail)
  end

  # `TABLE name` as a query body reads, and the planner refuses it (verified).
  defp select_term([{:word, _p, "TABLE", _l, _c}, {kind, printed, _u, _l2, _c2} | rest])
       when kind in [:word, :quoted] do
    case rest do
      [{:symbol, _s, ".", _l3, _c3} | _more] ->
        throw(:bail)

      _end_of_name ->
        Process.put(@planner, "Query TABLE #{SQLLiteral.unquoted(printed)} not implemented yet")
        rest
    end
  end

  defp select_term([{:word, _p, "TABLE", _l, _c}, token | _rest]), do: fail("Table name", [token])

  # The engine's parser reads a statement that changes data as a query body (inside parentheses,
  # after a set operator), and only the planner refuses it: its error for what follows is not
  # modelled.
  defp select_term([{:word, _p, word, _l, _c} | _rest])
       when word in ["INSERT", "UPDATE", "DELETE"] do
    refuse("an #{word} as a query body")
    throw(:bail)
  end

  defp select_term(tokens), do: fail("SELECT, VALUES, or a subquery in the query body", tokens)

  defp set_operations([{:word, _p, operator, _l, _c} | rest])
       when operator in ["UNION", "EXCEPT", "INTERSECT", "MINUS"] do
    Process.put(@set_operation, true)

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
    |> into_clause()
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

  # `INTO [TEMP] [UNLOGGED] [TABLE] name`, between the list and `FROM`.
  defp into_clause([{:word, _p, "INTO", _l, _c} | rest]) do
    Process.put(@into, if(Process.get(@depth) == 1, do: :plain, else: :nested))

    rest
    |> into_option(["TEMP", "TEMPORARY"])
    |> into_option(["UNLOGGED"])
    |> into_option(["TABLE"])
    |> into_name(1)
  end

  defp into_clause(tokens), do: tokens

  defp into_option([{:word, _p, word, _l, _c} | rest] = tokens, words),
    do: if(word in words, do: rest, else: tokens)

  defp into_option(tokens, _words), do: tokens

  defp into_name([{kind, _p, _u, _l, _c}, {:symbol, _q, ".", _l2, _c2} | rest], parts)
       when kind in [:word, :quoted, :string],
       do: into_name(rest, parts + 1)

  defp into_name([{kind, _p, _u, _l, _c} | rest], parts) when kind in [:word, :quoted, :string] do
    if parts > 3, do: refuse("an INTO target of #{parts} parts: the engine words its error")
    rest
  end

  defp into_name(tokens, _parts), do: fail("identifier", tokens)

  # `SELECT FROM t` selects no column.
  defp projection([{:word, _p, "FROM", _l, _c} | _rest] = tokens), do: tokens
  defp projection(tokens), do: tokens |> select_item() |> after_item()

  # A comma may end the list: before the end of the text, a closing bracket
  # or a word that cannot begin an item.
  defp after_item([{:symbol, _p, ",", _l, _c} | rest]) do
    case rest do
      [{:eof, _q, _u, _l2, _c2} | _more] -> rest
      [{:symbol, _q, bracket, _l2, _c2} | _more] when bracket in [")", "]", ";"] -> rest
      [{:word, _q, upper, _l2, _c2} | _more] when upper in @column_reserved -> rest
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
    do: if(upper in @column_reserved, do: tokens, else: rest)

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
        args |> call_arguments(nil) |> table_alias()

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
    do: if(upper in @table_reserved, do: tokens, else: alias_columns(rest))

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

  # `parse_expr`, which is `parse_subexpr(0)`.
  defp expression(tokens), do: counted(fn -> tokens |> operand() |> infix(0) end)

  # What can start an expression.
  defp operand([{kind, _p, _u, _l, _c} | rest])
       when kind in [:number, :string, :literal, :placeholder],
       do: rest

  defp operand([{:quoted, _p, _u, _l, _c} | _rest] = tokens), do: identifier(tokens)

  defp operand([{:symbol, _p, sign, _l, _c} | rest]) when sign in ["-", "+"],
    do: counted(fn -> rest |> operand() |> infix(@unary_precedence) end)

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

  defp word_operand(upper, [_word | more] = tokens) when upper in @typed_literals do
    case typed_literal(more) do
      nil -> identifier(tokens)
      rest -> rest
    end
  end

  # The engine reads these as the calls they are, with no parentheses; the double does not.
  defp word_operand(upper, [_word, {:symbol, _p, "(", _l, _c} | _rest] = tokens)
       when upper in @niladic,
       do: identifier(tokens)

  defp word_operand(upper, tokens) when upper in @niladic do
    refuse("#{String.downcase(upper)} without parentheses: write #{String.downcase(upper)}()")
    identifier(tokens)
  end

  defp word_operand(_upper, tokens), do: identifier(tokens)

  # The string after a type name in `TIMESTAMP '...'`, the type with its precision and
  # `WITH [OUT] TIME ZONE` as the engine reads them; `nil` when the text is no typed literal.
  defp typed_literal([{:string, _p, _u, _l, _c} | rest]), do: rest

  defp typed_literal([
         {:symbol, _p, "(", _l, _c},
         {:number, _q, _u, _l2, _c2},
         {:symbol, _r, ")", _l3, _c3} | more
       ]),
       do: typed_literal(more)

  defp typed_literal([
         {:word, _p, zone, _l, _c},
         {:word, _q, "TIME", _l2, _c2},
         {:word, _r, "ZONE", _l3, _c3} | more
       ])
       when zone in ["WITH", "WITHOUT"],
       do: typed_literal(more)

  defp typed_literal(_tokens), do: nil

  # A keyword with a syntax of its own that fails to parse is an identifier
  # (or a call of that name); when that fails too, the error is the
  # keyword's.
  @spec attempt(tokens(), (tokens() -> tokens())) :: tokens()
  defp attempt(tokens, special) do
    counted? = swallows?(tokens)
    if counted?, do: swallow(1)

    try do
      attempt_special(tokens, special)
    after
      if counted?, do: swallow(-1)
    end
  end

  defp attempt_special(tokens, special) do
    special.(tokens)
  catch
    {:syntax, _expected, _token} = error ->
      try do
        identifier(tokens)
      catch
        {:syntax, _other_expected, _other_token} -> throw(error)
      end

    # The limit's error inside a `NOT` chain is swallowed the same way (verified: forty-seven
    # `NOT`s are the parser error at the first token after the last one).
    :recursion ->
      identifier(tokens)
  end

  # The keywords that swallow the engine's errors and parse again are open frames, counted:
  # `CASE`, `CAST`, and a `NOT` whose operand is more than a name or a literal. A chain of `NOT`s
  # over a plain operand answers in linear time (verified to the limit), so it is not counted.
  defp swallows?([{:word, _p, "NOT", _l, _c}, {:word, _q, "NOT", _l2, _c2} | _rest]), do: false

  defp swallows?([{:word, _p, "NOT", _l, _c}, next | after_next]),
    do: not plain_operand?(next, after_next)

  defp swallows?(_tokens), do: true

  defp plain_operand?({kind, _p, _u, _l, _c}, _rest)
       when kind in [:number, :string, :literal, :placeholder, :quoted],
       do: true

  defp plain_operand?({:word, _p, upper, _l, _c}, [{:symbol, _q, "(", _l2, _c2} | _rest])
       when is_binary(upper),
       do: false

  defp plain_operand?({:word, _p, upper, _l, _c}, _rest),
    do:
      upper not in @opaque_words and upper not in @special_calls and
        upper not in @typed_literals and upper not in @niladic and
        upper not in ["CASE", "CAST", "INTERVAL", "NOT"]

  defp plain_operand?(_token, _rest), do: false

  defp swallow(step) do
    level = Process.get(@swallow, 0) + step
    if level > @swallow_limit, do: throw({:fail, nesting_refusal()})
    Process.put(@swallow, level)
  end

  # `NOT` takes the operators that bind tighter than `AND`.
  defp not_operand([_not | rest]),
    do: counted(fn -> rest |> operand() |> infix(@not_precedence) end)

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

  # The type of a cast, read by the one grammar of types (`SQLDmlType`): a name, its size, the
  # words that go with it, the array suffixes. A type it cannot read is the engine's parser
  # error at the token; one it reads and the double does not is refused by name.
  defp data_type([{:word, _p, _u, _l, _c} | _rest] = tokens), do: read_type(tokens, true)
  defp data_type([{:quoted, printed, _u, _l, _c} | rest]), do: unsupported_type(printed, rest)
  defp data_type(tokens), do: fail("a data type name", tokens)

  defp type_name(tokens), do: read_type(tokens, false)

  defp read_type(tokens, in_cast?) do
    case SQLDmlType.parse(tokens) do
      {:ok, _type, rest} ->
        rest

      {:error, error} ->
        throw({:fail, error})

      {:refuse, "the type " <> _name = reason} when in_cast? ->
        custom_type(tokens, reason)

      {:refuse, reason} ->
        refuse("a cast to #{reason}")
        throw(:bail)
    end
  end

  # A type name of the user's (the engine plans none): the parser takes the name and expects
  # the end of the cast, so a word after it is its error (`CAST(n AS f TIMESTAMP)`, verified);
  # a name alone is the planner's 405, which the double refuses.
  defp custom_type([_name, {:word, _p, _u, _l, _c} | _rest] = tokens, _reason),
    do: tokens |> tl() |> close_paren()

  defp custom_type(_tokens, reason) do
    refuse("a cast to #{reason}")
    throw(:bail)
  end

  # `INTERVAL '1 minute'` and `INTERVAL '1' minute`. The engine's planner reads no `TO`
  # field and no precision (405); an interval of any other expression is not read here.
  defp interval([_interval, {kind, printed, _u, _l, _c} | rest])
       when kind in [:string, :number] do
    interval_overflow(kind, printed, rest)
    {unit_end, precision} = rest |> interval_unit() |> interval_precision()

    case interval_to(unit_end) do
      {:to, last_field, more} ->
        unsupported_interval("last_field Some(#{last_field})", more)

      :none ->
        if precision,
          do: unsupported_interval("leading_precision Some(#{precision})", unit_end),
          else: unit_end
    end
  end

  defp interval([_interval | rest]) do
    _read = operand(rest)
    refuse("an INTERVAL of an expression that is not a string or a number")
    throw(:bail)
  end

  # An interval literal that does not fit one is the engine's error as the literal is read.
  defp interval_overflow(kind, printed, rest) do
    text = if kind == :string, do: String.slice(printed, 1..-2//1), else: printed

    unit =
      case rest do
        [{:word, _q, unit, _l, _c} | _more] when unit in @interval_units -> unit
        _no_unit -> nil
      end

    with message when is_binary(message) <- SQLInterval.overflow(text, unit),
         true <- is_nil(Process.get(@arrow)) do
      Process.put(@arrow, message)
    end

    :ok
  end

  defp interval_unit([{:word, _q, unit, _l, _c} | more]) when unit in @interval_units, do: more
  defp interval_unit(tokens), do: tokens

  defp interval_precision([{:symbol, _p, "(", _l, _c}, {:number, _q, digits, _l2, _c2} | more]) do
    case more do
      [{:symbol, _r, ")", _l3, _c3} | after_precision] ->
        if digits =~ ~r/\A\d+\z/,
          do: {after_precision, String.to_integer(digits)},
          else: no_precision()

      _other ->
        no_precision()
    end
  end

  defp interval_precision(tokens), do: {tokens, nil}

  defp no_precision do
    refuse("an INTERVAL precision this grammar does not read")
    throw(:bail)
  end

  defp interval_to([{:word, _p, "TO", _l, _c} | rest]) do
    case rest do
      [{:word, _q, field, _l2, _c2} | more] when field in @interval_units ->
        {:to, String.capitalize(field), more}

      [{:word, _q, _other, _l2, _c2} | _more] ->
        refuse("an INTERVAL ... TO field this grammar does not read")
        throw(:bail)

      tokens ->
        fail("date/time field", tokens)
    end
  end

  defp interval_to(_tokens), do: :none

  defp unsupported_interval(what, rest) do
    defer("Unsupported Interval Expression with " <> what)
    rest
  end

  # A type written as a quoted name is the planner's error (`i::"int"`, verified on Core for any
  # name, `"int"` and `"foo"` alike), found where the cast is converted, which the text's other
  # errors may come before: the double answers it where the text names no table and no column.
  @spec unsupported_type(binary(), tokens()) :: tokens()
  defp unsupported_type(printed, rest) do
    defer("Unsupported SQL type " <> printed)
    rest
  end

  # The planner's refusal the text will get once it reads; the first one stands.
  @spec defer(binary()) :: :ok
  defp defer(message) do
    if is_nil(Process.get(@planner)), do: Process.put(@planner, message)
    :ok
  end

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

  defp skip_to_close([{:symbol, _p, "(", _l, _c} | rest], depth) do
    if depth + Process.get(@recursion, 0) > @unread_limit, do: throw({:fail, nesting_refusal()})
    skip_to_close(rest, depth + 1)
  end

  defp skip_to_close([_token | rest], depth), do: skip_to_close(rest, depth)

  # A name, a name with qualifiers, or a call.
  defp identifier([name | rest]) do
    case qualified(rest) do
      [{:symbol, _p, "(", _l, _c} | args] ->
        called(name)
        args |> call_arguments(name) |> after_call()

      after_name ->
        after_name
    end
  end

  # A function the double does not know, called before any named argument, is noted: the
  # engine's error for it may come first.
  defp called({:word, printed, _upper, _l, _c}) do
    if is_nil(Process.get(@named)) and not SQLNamedArg.known?(printed),
      do: Process.put(@unknown_call, Process.get(@unknown_call) || printed)

    :ok
  end

  defp called(_name), do: :ok

  defp qualified([{:symbol, _p, ".", _l, _c}, {kind, _q, _u, _l2, _c2} | rest])
       when kind in [:word, :quoted],
       do: qualified(rest)

  defp qualified([{:symbol, _p, ".", _l, _c}, {:symbol, _q, "*", _l2, _c2} | rest]),
    do: wildcard_options(rest)

  defp qualified(tokens), do: tokens

  defp call_arguments([{:symbol, _p, ")", _l, _c} | rest], _name), do: rest

  defp call_arguments([{:word, _p, quantifier, _l, _c} | rest], name)
       when quantifier in ["DISTINCT", "ALL"],
       do: argument_list(rest, name)

  defp call_arguments(tokens, name), do: argument_list(tokens, name)

  defp argument_list(tokens, name) do
    case tokens |> argument(name) |> argument_order() do
      [{:symbol, _p, ",", _l, _c} | rest] -> argument_list(rest, name)
      [{:symbol, _p, ")", _l, _c} | rest] -> rest
      [{:word, _p, word, _l, _c} | _rest] when word in ["IGNORE", "RESPECT", "ON"] -> throw(:bail)
      other -> fail(")", other)
    end
  end

  # An argument is an expression, the `*` of `count(*)`, or `name => expression`. The parser
  # tries the named form first and, when what follows the arrow does not read, goes back and
  # reads the name as an expression, so the error is at the arrow (`abs(x => )`).
  defp argument([{:symbol, _p, "*", _l, _c} | rest], _name), do: rest

  defp argument([{kind, _p, _u, _l, _c}, {:symbol, _q, "=>", _l2, _c2} | value] = tokens, name)
       when kind in [:word, :quoted, :string] do
    named(name)

    try do
      expression(value)
    catch
      {:syntax, _expected, _token} -> fail(")", tl(tokens))
    end
  end

  defp argument(tokens, _name), do: expression(tokens)

  defp named(nil), do: :ok

  defp named(name) do
    if is_nil(Process.get(@named)), do: Process.put(@named, {name, Process.get(@unknown_call)})
    :ok
  end

  # `first_value(x ORDER BY t)`.
  defp argument_order([{:word, _p, "ORDER", _l, _c}, {:word, _q, "BY", _l2, _c2} | rest]),
    do: order_items(rest)

  defp argument_order(tokens), do: tokens

  defp after_call([{:word, _p, word, _l, _c} | _rest]) when word in @after_call_bail,
    do: throw(:bail)

  defp after_call(tokens), do: tokens

  # What can follow an operand and go on with the expression, as `parse_subexpr(min)` reads
  # it: an operator binds only if its precedence is above `min`, and the right operand of an
  # operator is a `parse_subexpr` of its own precedence, one level deeper in the recursion.
  defp infix(tokens, min) do
    precedence = step_precedence(tokens)

    if precedence > min,
      do: tokens |> infix_step(precedence) |> infix(min),
      else: tokens
  end

  # The precedence the engine's parser gives the operator at the head of the tokens (sqlparser
  # `Precedence`), 0 where none continues an expression.
  defp step_precedence([{:word, _p, "NOT", _l, _c}, {:word, _q, "NULL", _l2, _c2} | _more]),
    do: 17

  defp step_precedence([{:word, _p, "NOT", _l, _c}, {:word, _q, next, _l2, _c2} | _more]),
    do: not_precedence(next)

  defp step_precedence([{:word, _p, word, _l, _c} | _rest]),
    do: Map.get(@word_precedence, word, 0)

  defp step_precedence([{:symbol, _p, symbol, _l, _c} | _rest]) do
    cond do
      symbol in ["::", "[", "->", ":", "("] -> 50
      symbol in ["*", "/", "%", "//"] -> 40
      symbol in ["+", "-"] -> 30
      symbol == "&" -> 23
      symbol == "^" -> 22
      symbol == "|" -> 21
      symbol in ["=", "==", "<", ">", "<=", ">=", "<>", "!=", "<=>"] -> 20
      symbol in ["~~", "~~*", "!~~", "!~~*"] -> 19
      symbol in ["||", "~", "!~", "~*", "!~*", "<<", ">>"] -> 16
      true -> 0
    end
  end

  defp step_precedence(_tokens), do: 0

  defp not_precedence(next) when next in ["IN", "BETWEEN"], do: 20
  defp not_precedence(next) when next in ["LIKE", "ILIKE", "SIMILAR"], do: 19
  defp not_precedence(_next), do: 0

  # `DIV` has a precedence on the engine's parser and no infix parser behind it.
  defp infix_step([{:word, printed, "DIV", line, col} | _rest], _precedence) do
    throw(
      {:fail,
       SQLError.parser(
         "No infix parser for token Word(Word { value: \"#{printed}\", quote_style: None, " <>
           "keyword: DIV }) at Line: #{line}, Column: #{col}"
       )}
    )
  end

  defp infix_step([{:symbol, _p, "//", _l, _c} | rest], precedence) do
    defer("Operator DIV is not yet supported")
    right_operand(rest, precedence)
  end

  defp infix_step([{:symbol, _p, like, _l, _c} | rest], precedence)
       when like in ["~~", "~~*", "!~~", "!~~*"] do
    refuse("the operators ~~, ~~*, !~~ and !~~*: write LIKE, ILIKE, NOT LIKE or NOT ILIKE")
    right_operand(rest, precedence)
  end

  defp infix_step([{:symbol, _p, "<=>", _l, _c} | rest], precedence) do
    refuse("the null-safe equality operator <=>: write IS NOT DISTINCT FROM")
    right_operand(rest, precedence)
  end

  defp infix_step([{:symbol, _p, symbol, _l, _c} | rest], precedence) when symbol in @operators,
    do: right_operand(rest, precedence)

  defp infix_step(
         [{:symbol, _p, "::", _l, _c}, {:quoted, printed, _u, _l2, _c2} | rest],
         _precedence
       ),
       do: unsupported_type(printed, rest)

  defp infix_step(
         [{:symbol, _p, "::", _l, _c}, {:word, _q, _u, _l2, _c2} | _rest] = tokens,
         _precedence
       ),
       do: type_name(tl(tokens))

  defp infix_step([{:symbol, _p, symbol, _l, _c} | _rest], _precedence)
       when symbol in ["::", "[", "->", ":", "("],
       do: throw(:bail)

  defp infix_step(
         [{:word, _p, "NOT", _l, _c}, {:word, _q, "NULL", _l2, _c2} | rest],
         _precedence
       ),
       do: rest

  defp infix_step([{:word, _p, word, _l, _c} | rest], precedence) when word in @logical_words,
    do: right_operand(rest, precedence)

  defp infix_step([{:word, _p, word, _l, _c} | rest], precedence) when word in @predicate_words,
    do: predicate(rest, word, precedence)

  defp infix_step(
         [{:word, _p, "NOT", _l, _c}, {:word, _q, word, _l2, _c2} | rest],
         precedence
       )
       when word in @negatable_words,
       do: predicate(rest, word, precedence)

  # `SIMILAR TO` is an operator the double does not read; a `SIMILAR` with no `TO` after it is
  # the engine's parse error, found at the word.
  defp infix_step([{:word, _p, "SIMILAR", _l, _c}, {:word, _q, "TO", _l2, _c2} | _rest], _prec),
    do: throw(:bail)

  defp infix_step([{:word, _p, "SIMILAR", _l, _c} | _rest] = tokens, _precedence),
    do: fail("IN or BETWEEN after NOT", tokens)

  defp infix_step(
         [
           {:word, _p, "NOT", _l, _c},
           {:word, _q, "SIMILAR", _l2, _c2},
           {:word, _r, "TO", _l3, _c3} | _rest
         ],
         _precedence
       ),
       do: throw(:bail)

  defp infix_step(
         [{:word, _p, "NOT", _l, _c} | [{:word, _q, "SIMILAR", _l2, _c2} | _more] = tokens],
         _precedence
       ),
       do: fail("IN or BETWEEN after NOT", tokens)

  defp infix_step([{:word, _p, word, _l, _c} | _rest], _precedence)
       when word in ["COLLATE", "AT", "ISNULL", "NOTNULL", "ESCAPE", "NULL"],
       do: throw(:bail)

  # The right operand of an operator: a `parse_subexpr` of the operator's precedence.
  defp right_operand(tokens, precedence),
    do: counted(fn -> tokens |> operand_after_operator() |> infix(precedence) end)

  defp operand_after_operator([{:word, _p, word, _l, _c}, {:symbol, _q, "(", _l2, _c2} | _rest])
       when word in ["ANY", "ALL", "SOME"],
       do: throw(:bail)

  defp operand_after_operator(tokens), do: operand(tokens)

  defp predicate(tokens, "IS", precedence), do: predicate_tail(tokens, precedence)
  defp predicate(tokens, "IN", _precedence), do: in_list(tokens)
  defp predicate(tokens, "BETWEEN", _precedence), do: between(tokens)

  defp predicate(tokens, _like, precedence),
    do: tokens |> like_pattern(precedence) |> like_escape()

  defp like_pattern(tokens, precedence),
    do: counted(fn -> tokens |> operand() |> infix(precedence) end)

  defp like_escape([{:word, _p, "ESCAPE", _l, _c}, {:string, _q, _u, _l2, _c2} | rest]), do: rest
  defp like_escape(tokens), do: tokens

  @is_expected "[NOT] NULL | TRUE | FALSE | DISTINCT | [form] NORMALIZED FROM after IS"

  defp predicate_tail([{:word, _p, "NOT", _l, _c} | rest], precedence),
    do: after_is(rest, precedence)

  defp predicate_tail(tokens, precedence), do: after_is(tokens, precedence)

  defp after_is([{:word, _p, word, _l, _c} | rest], _precedence)
       when word in ["NULL", "TRUE", "FALSE", "UNKNOWN"],
       do: rest

  defp after_is(
         [{:word, _p, "DISTINCT", _l, _c}, {:word, _q, "FROM", _l2, _c2} | rest],
         precedence
       ),
       do: right_operand(rest, precedence)

  defp after_is([{:word, _p, "NORMALIZED", _l, _c} | _rest], _precedence), do: throw(:bail)
  defp after_is(tokens, _precedence), do: fail(@is_expected, tokens)

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

  # Each bound is a `parse_subexpr` of `BETWEEN`'s precedence.
  defp between(tokens) do
    counted(fn -> tokens |> operand() |> before_and() end)
    |> expect_word("AND")
    |> between_high()
  end

  defp between_high(tokens),
    do: counted(fn -> tokens |> operand() |> infix(@between_precedence) end)

  # The low bound of a `BETWEEN` stops at the `AND` that belongs to it.
  defp before_and([{:word, _p, "AND", _l, _c} | _rest] = tokens), do: tokens

  defp before_and([{:symbol, _p, symbol, _l, _c} | rest]) when symbol in @bound_operators,
    do: rest |> operand() |> before_and()

  # A cast of the low bound (`BETWEEN 1::bigint AND 3`).
  defp before_and([{:symbol, _p, "::", _l, _c}, {:word, _q, _u, _l2, _c2} | _rest] = tokens),
    do: tokens |> tl() |> type_name() |> before_and()

  defp before_and([{:symbol, _p, "::", _l, _c}, {:quoted, printed, _u, _l2, _c2} | rest]),
    do: printed |> unsupported_type(rest) |> before_and()

  defp before_and(tokens), do: tokens
end
