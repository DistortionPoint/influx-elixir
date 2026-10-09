defmodule InfluxElixir.Client.Local.InfluxQLParser do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
  # Reads an InfluxQL `SELECT` into the query map `InfluxElixir.Client.Local.InfluxQL`
  # shapes and plans: the clauses are located on a mask of the statement (so a
  # keyword inside a literal is no keyword), checked as the engine's parser
  # checks them (`InfluxElixir.Client.Local.InfluxQLCheck`), and a statement after
  # a `;` is read the same way.

  alias InfluxElixir.Client.Local.{
    InfluxQL,
    InfluxQLArgs,
    InfluxQLBlanks,
    InfluxQLCheck,
    InfluxQLClauseScan,
    InfluxQLError,
    InfluxQLExpr,
    InfluxQLGroup,
    InfluxQLLex,
    InfluxQLLiteral,
    InfluxQLNames,
    InfluxQLSelectCheck,
    InfluxQLSources,
    InfluxQLText,
    InfluxQLTokens
  }

  @aggregates ~w(mean sum count min max first last median spread stddev distinct)
  @only_one "must provide only one InfluxQl statement per query"
  @single_database "error in InfluxQL statement: can only perform queries on a single database"
  @no_variable "field must contain at least one variable"
  @cr_with_error "unsupported InfluxQL (a carriage return after a keyword in a select list " <>
                   "that has another error)"

  # Regexes nested in a list cannot be module attributes on OTP 28, so the
  # table is a function.
  @spec unsupported() :: [{Regex.t(), binary()}]
  defp unsupported do
    [
      {~q/\bINTO\b/i, "INTO"},
      {~q/\bFROM\s*\(/i, "subqueries"},
      {~q/(?<![A-Za-z_\d])\d+(?:\.\d+)?FROM(?![\w])/i, "a number directly against FROM"},
      {~q/(?<![A-Za-z_\d])\d+(?:\.\d+)?AS(?![\w])/i, "a number directly against AS"}
    ]
  end

  # The select list, and the text after `FROM` when a source starts there (the list of sources
  # itself is read by `InfluxQLSources`).
  @select Regex.compile!(
            InfluxElixir.Client.Local.InfluxQLBlankRegex.blank_pattern(
              "^\\s*SELECT(?:\\s+|(?=[*(]))(?<items>.+?)(?:\\s+|(?<=#{InfluxQLText.item_end_class()}))FROM(?:\\s+|(?=/))" <>
                "(?=#{InfluxQLSources.source_pattern()})(?<tail>.*)$"
            ),
            "is"
          )

  @function ~q/^(?<fn>[A-Za-z_]\w*)\s*\(\s*(?<arg>\*|"[^"]+"|'(?:[^'\\]|\\.)*'|[+-]?[\w.]+)\s*\)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is
  @literal ~q/^(?:'(?:[^'\\]|\\.)*'|[+-]?(?:\d+\.\d+|\.\d+|\d+)|(?:\d+(?:ns|ms|u|µ|s|m|h|d|w))+|true|false)(?:\s+AS\s+(?:"[^"]+"|\w+))?$/isu
  @count_distinct ~q/^count\s*\(\s*distinct(?:\s*\(\s*(?<arg>"[^"]+"|[A-Za-z_][\w.]*)\s*\)|\s+(?<bare>"[^"]+"|[A-Za-z_][\w.]*))\s*\)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is
  @column ~q/^(?<col>"[^"]+"|[\w.]+)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is

  @doc """
  Parses an InfluxQL `SELECT`. Returns `{:error, message}` for syntax the
  engine rejects and for the constructs listed in the moduledoc.
  """
  @spec parse(binary()) ::
          {:ok, InfluxQL.query()}
          | {:error, binary() | {:engine, binary()} | {:engine, pos_integer(), binary()}}
  def parse(statement) do
    case parse_statement(statement) do
      {:error, :unread_shape} ->
        {:error, "unsupported InfluxQL (that shape of statement)"}

      {:error, :unread_order} ->
        {:error, "unsupported InfluxQL (clauses the double does not read in that order)"}

      {:error, {:engine, body}} ->
        {:error, {:engine, echo_comments(body, statement)}}

      other ->
        other
    end
  end

  # An error that quotes the rest of the statement quotes it as sent, comments and all
  # (verified: `WHERE --host = 0` is `Nom("where --host = 0", Tag)`); the double blanks a
  # comment byte for byte to read the statement, so the quoted text is put back.
  @spec echo_comments(binary(), binary()) :: binary()
  defp echo_comments(body, statement) do
    {clean, _masked, _unclosed} = blank_comments(statement, InfluxQLText.mask_literals(statement))

    with true <- clean != statement,
         [_all, {at, length}] <-
           Regex.run(~q/Nom\((".*"), (?:Tag|Char)\)$/s, body, return: :index),
         quoted = binary_part(body, at, length),
         from when from != nil <- InfluxQLError.quoted_start(quoted, clean) do
      size = byte_size(clean)

      binary_part(body, 0, at) <>
        InfluxQLError.rust_debug(binary_part(statement, from, size - from)) <>
        binary_part(body, at + length, byte_size(body) - at - length)
    else
      _unquoted -> body
    end
  end

  # `parse/1` with the statements it cannot read as atoms: a statement after a
  # `;` that does not read is judged by what it looks like.
  @spec parse_statement(binary()) ::
          {:ok, InfluxQL.query()} | {:error, atom() | binary() | tuple()}
  defp parse_statement(statement) do
    {clean, masked, unclosed} = blank_comments(statement, InfluxQLText.mask_literals(statement))
    {head, masked_head, tail} = split_statement(clean, masked)
    lexer = lexer_of(clean, unclosed, head)

    with :ok <- not_a_token_to_start(clean),
         :ok <- check_blanks(masked_head),
         :ok <- check_supported(masked_head),
         :ok <- check_select(clean, masked_head, lexer),
         %{"items" => items, "tail" => after_from} <-
           slices(@select, masked_head, head) || unread(lexer, :unread_shape),
         %{"items" => masked_items, "tail" => masked_after_from} =
           slices(@select, masked_head, masked_head),
         {:ok, sources, size} <- sources_end(masked_after_from, after_from, head, lexer),
         {_from, rest} = split_at(after_from, size),
         {_masked_from, masked_rest} = split_at(masked_after_from, size),
         at = byte_size(head) - byte_size(rest),
         :ok <- InfluxQLCheck.settle([InfluxQLCheck.check_empty_where(clean, at, masked_rest)]),
         masked_all = masked_rest,
         {group_result, masked_rest, rest} = InfluxQLGroup.extract(clean, at, masked_rest),
         %{} = clauses <-
           slices(InfluxQLText.clauses(), masked_rest, rest) ||
             [lexer, clauses_error(clean, at, {masked_all, masked_rest}, rest)]
             |> InfluxQLCheck.settle(clean)
             |> readable_items_first(items, masked_items),
         {where, swallowed} = InfluxQLCheck.cut_where(masked_rest, clauses["where"]),
         :ok <-
           [
             lexer,
             InfluxQLBlanks.clauses(clean, at, masked_all),
             InfluxQLCheck.check_where_call(clean, at, masked_rest, where),
             InfluxQLCheck.check_where(clean, at, masked_rest, where),
             group_error(group_result),
             InfluxQLCheck.check_group(clean, at, masked_rest),
             InfluxQLCheck.check_operands(clean, at, masked_rest, swallowed)
           ]
           |> InfluxQLCheck.settle(clean)
           |> readable_items_first(items, masked_items),
         {:ok, sources, database} <- single_database(sources),
         {:ok, group} <- group_of(group_result, clauses),
         {:ok, items} <- parse_items(items, masked_items),
         {:ok, items} <- InfluxQLNames.resolve(items),
         :ok <- check_single(statement, tail),
         :ok <- check_tz(clauses),
         :ok <- where_refusal(where),
         :ok <- not_implemented(clauses) do
      {:ok,
       %{
         items: items,
         measurement: measurement_name(sources),
         sources: sources,
         database: database,
         where: where,
         group_by: group.dimensions,
         group_time: group.time,
         fill: group.fill || :null,
         descending: String.upcase(clauses["dir"]) == "DESC",
         limit: to_int(clauses["limit"]),
         offset: to_int(clauses["offset"]) || 0,
         rewrite_error: Map.get(group, :rewrite_error),
         tz: clauses["tzcall"] != ""
       }}
    end
  end

  # Where the list of sources after `FROM` ends (see `InfluxQLSources`): a first source that does
  # not read is the engine's "invalid FROM clause" where it starts. `masked` is the text after
  # `FROM` with its literals masked, `raw` the same text as sent.
  @spec sources_end(binary(), binary(), binary(), InfluxQLCheck.lexer() | nil) ::
          {:ok, [InfluxQLSources.source()], non_neg_integer()} | {:error, term()}
  defp sources_end(masked, raw, head, lexer) do
    from_at = byte_size(head) - byte_size(masked)

    case InfluxQLSources.split(masked, raw) do
      {:ok, sources, size} ->
        {:ok, sources, size}

      # The name after the dot is read, then found missing: a literal left open there is the
      # lexer's error, met before.
      {:missing_name, %{wanted_at: wanted_at}} ->
        error =
          {from_at + wanted_at + 1,
           {:error, {:engine, InfluxQLError.syntax_error_body(:from, from_at, head)}}}

        InfluxQLCheck.settle([lexer, error], head)

      :none ->
        unread(lexer, :unread_shape)
    end
  end

  # A statement names one database (verified): sources written with different qualifiers (one
  # qualified beside one that is not, `n.m` beside `k.a`, `db..m` beside `db.autogen.a`) are the
  # engine's error. A name with three parts (`db.rp.m`, `db..m`) names the database it must be
  # run in: `db` alone for the retention policy `autogen` or none, else `db/rp` (the form the
  # engine's own parameter takes); one with two (`rp.m`) names the retention policy, which the
  # engine ignores.
  @spec single_database([InfluxQLSources.source()]) ::
          {:ok, [{:name | :regex, binary()}], binary() | nil} | {:error, term()}
  defp single_database([{_source, qualifiers} | _more] = sources) do
    if Enum.all?(sources, &match?({_source, ^qualifiers}, &1)),
      do: {:ok, Enum.map(sources, &elem(&1, 0)), database_named(qualifiers)},
      else: {:error, {:engine, @single_database}}
  end

  defp database_named([database, rp]) when rp in [nil, "autogen"], do: database
  defp database_named([database, rp]), do: database <> "/" <> rp
  defp database_named(_none_or_policy), do: nil

  @spec split_at(binary(), non_neg_integer()) :: {binary(), binary()}
  defp split_at(text, size),
    do: {binary_part(text, 0, size), binary_part(text, size, byte_size(text) - size)}

  # A statement starts with a keyword: one that starts with a quote or a slash is left unparsed
  # from there, as the text it is (the lexer reads no string or regular expression where the
  # statement list wants a keyword: verified for `'`, `'x`, `"x`, `/x`, with blanks before).
  #
  # Text that starts with no statement keyword is left unparsed whole (verified: `foo`,
  # `(select n from m)`, `drop`, `sebect ...` whatever the rest holds, a literal or a comment
  # never closed included: the lexer is not reached), and so is `SELECT` directly against a
  # character that is no blank and no character of an operator, a parenthesis or `;` (`select"n`,
  # `select#n`, `select:n`; against the others the keyword is read and the select list is what
  # fails). Nothing but blanks, comments and `;` is no statement at all, and a text that starts
  # with a `;` is read as before.
  @select_glue Regex.compile!(
                 InfluxElixir.Client.Local.InfluxQLBlankRegex.blank_pattern(
                   "\\ASELECT[^\\w\\s;" <> InfluxQLText.operator_glue_chars() <> "]"
                 ),
                 "i"
               )
  @statement_start ~q/\A(?:(?:SELECT|SHOW|EXPLAIN|CREATE|DELETE)(?![\w])|DROP(?![\w])\s*\S)/i

  @spec not_a_token_to_start(binary()) :: :ok | {:error, {:engine, binary()}}
  defp not_a_token_to_start(clean) do
    text = InfluxQLLex.trim_blanks(clean)

    cond do
      text =~ ~q/\A[\s;]*\z/ -> {:error, {:engine, @only_one}}
      text =~ ~q/\A;/ -> :ok
      text =~ @statement_start and not (text =~ @select_glue) -> :ok
      true -> {:error, {:engine, InfluxQLError.syntax_error_body(:nom, 0, clean)}}
    end
  end

  # A `--` outside a literal comments out the rest of its line, `/* ... */`
  # (not nested) comments out what it holds. The comment becomes spaces, byte
  # for byte, in the statement and its mask, so every offset stays the
  # engine's. A `/*` never closed is the lexer's error at the `*` (verified),
  # returned as its position.
  @comments ~q/--[^\n]*|\/\*.*?\*\/|\/\*/s

  @spec blank_comments(binary(), binary()) :: {binary(), binary(), non_neg_integer() | nil}
  defp blank_comments(statement, masked) do
    comments =
      @comments
      |> Regex.scan(masked, return: :index)
      |> List.flatten()
      |> Enum.reject(&regex_closing?(&1, masked))

    unclosed =
      Enum.find_value(comments, fn {at, size} ->
        if size == 2 and binary_part(masked, at, 2) == "/*", do: at + 2
      end)

    {Enum.reduce(comments, statement, &blank/2), Enum.reduce(comments, masked, &blank/2),
     unclosed}
  end

  # The slash that closes `=~ /re/` or a regular expression for columns (`SELECT /re/*`) is not
  # the start of a comment.
  @spec regex_closing?({non_neg_integer(), non_neg_integer()}, binary()) :: boolean()
  defp regex_closing?({at, _size}, masked) when at > 0 do
    binary_part(masked, at, 2) == "/*" and
      (binary_part(masked, 0, at) =~ ~q/[=!]~\s*\/_*$/ or
         binary_part(masked, 0, at) =~ ~q/(?:\bSELECT\s+|,\s*|\(\s*)\/(?:[^\/\\]|\\.)*\z/i)
  end

  defp regex_closing?(_comment, _masked), do: false

  # The lexer's error of the statement's head (an unterminated quote, regular expression or
  # comment), when the token starts in it: one in a statement after a `;` is that statement's.
  @spec lexer_of(binary(), non_neg_integer() | nil, binary()) :: InfluxQLCheck.lexer() | nil
  defp lexer_of(clean, unclosed, head) do
    case InfluxQLCheck.lexer_error(clean, unclosed) do
      {:lexer, start, _error} = lexer when start < byte_size(head) -> lexer
      _in_a_later_statement -> nil
    end
  end

  # The select list and `FROM` as the engine's parser reads them: the leftmost of the errors of
  # the list, a lexer error in it (met while the parser reads the list) and a carriage return
  # right after `SELECT`, `AS` or `FROM` (the statement is left unparsed, see `InfluxQLBlanks`).
  # Of that carriage return and another error in the list the double cannot tell which comes
  # first, and refuses. After the list a lexer error takes its place among the parse errors of
  # the clauses (`InfluxQLCheck.leftmost/2`).
  @spec check_select(binary(), binary(), InfluxQLCheck.lexer() | nil) :: :ok | {:error, term()}
  defp check_select(clean, masked_head, lexer) do
    cr = InfluxQLBlanks.select_stage(clean, masked_head)
    list = InfluxQLSelectCheck.check_select(clean, masked_head)

    case {cr, InfluxQLCheck.leftmost([cr, list, lexer_in_list(lexer, masked_head)], clean)} do
      {_cr, nil} -> :ok
      {{0, error}, _picked} -> error
      {cr, cr} when list != nil -> cr_with_list(cr, list, masked_head)
      {_cr, {_key, error}} -> error
    end
  end

  # The list's own error when it is the very defect of the keyword (`FROM` against a non-blank
  # has no source after it: the error stands directly past the keyword): the statement is then
  # left unparsed, as for any other. Another error in the list may come first: refused.
  @spec cr_with_list(InfluxQLCheck.positioned(), InfluxQLCheck.positioned(), binary()) ::
          {:error, term()}
  # Two errors that are one answer (both leave the whole statement unparsed) are that answer.
  defp cr_with_list({_key, error}, {_list_key, error}, _masked_head), do: error

  defp cr_with_list({key, error}, {list_key, _error}, masked_head) do
    word = binary_part(masked_head, key, min(4, byte_size(masked_head) - key))
    size = if String.downcase(word) == "from", do: 4, else: 2
    if list_key == key + size, do: error, else: {:error, @cr_with_error}
  end

  @spec lexer_in_list(InfluxQLCheck.lexer() | nil, binary()) :: InfluxQLCheck.lexer() | nil
  defp lexer_in_list({:lexer, start, _error} = lexer, masked_head) do
    list_end =
      case Regex.run(InfluxQLText.from_keyword(), masked_head, return: :index) do
        [{from, _size}] -> from
        nil -> byte_size(masked_head)
      end

    if start < list_end, do: lexer
  end

  defp lexer_in_list(nil, _masked_head), do: nil

  # The error of a statement that does not have the shape of a `SELECT`: a lexer error of the
  # head is the one the engine finds first.
  @spec unread(InfluxQLCheck.lexer() | nil, atom()) :: {:error, term()}
  defp unread(nil, reason), do: {:error, reason}
  defp unread({:lexer, _start, error}, _reason), do: error

  @spec blank({non_neg_integer(), non_neg_integer()}, binary()) :: binary()
  defp blank({from, length}, text) do
    <<before::binary-size(from), _comment::binary-size(length), rest::binary>> = text
    before <> String.duplicate(" ", length) <> rest
  end

  # The statement up to its first `;` outside a literal, with its mask, and
  # the offset just after the `;` (`nil` without one).
  @spec split_statement(binary(), binary()) ::
          {binary(), binary(), non_neg_integer() | nil}
  defp split_statement(clean, masked) do
    case :binary.match(masked, ";") do
      {at, 1} ->
        {binary_part(clean, 0, at), binary_part(masked, 0, at), at + 1}

      :nomatch ->
        {clean, masked, nil}
    end
  end

  # What follows a statement's `;` is another statement or nothing. The
  # engine takes one statement per query (verified): a second that reads is
  # "only one InfluxQl statement per query", and what does not read is its
  # own parse error at the position it starts, the rest of the text shown.
  # Repeated `;` and whitespace between are skipped.
  @spec check_single(binary(), non_neg_integer() | nil) :: :ok | {:error, term()}
  defp check_single(_statement, nil), do: :ok

  defp check_single(statement, after_semicolon) do
    rest = binary_part(statement, after_semicolon, byte_size(statement) - after_semicolon)
    {clean_rest, _masked, _unclosed} = blank_comments(rest, InfluxQLText.mask_literals(rest))
    [skipped] = Regex.run(~q/^[\s;]*/, clean_rest)
    start = after_semicolon + byte_size(skipped)

    case binary_part(statement, start, byte_size(statement) - start) do
      "" -> :ok
      next -> next_statement_error(statement, next, start)
    end
  end

  @other_statements ~q/^SHOW\s+(?:DATABASES|MEASUREMENTS|TAG\s+(?:KEYS|VALUES)|FIELD\s+KEYS)\b/i

  # Statements the engine reads in ways the double does not follow; any
  # other text is not a statement at all, and the engine fails it where it
  # starts (verified).
  @known_statements ~q/^(?:(?:SELECT|SHOW|EXPLAIN|CREATE|DELETE)(?![\w])|DROP(?![\w])\s*\S)/i

  @spec next_statement_error(binary(), binary(), non_neg_integer()) :: {:error, term()}
  defp next_statement_error(statement, next, start) do
    case parse_statement(next) do
      {:ok, _query} ->
        {:error, {:engine, @only_one}}

      {:error, {:engine, body}} ->
        {:error, {:engine, InfluxQLError.shift_position(body, start)}}

      {:error, "unsupported" <> _rest} = refusal ->
        refusal

      {:error, reason} ->
        cond do
          Regex.match?(@other_statements, next) ->
            {:error, {:engine, @only_one}}

          Regex.match?(@known_statements, next) ->
            {:error, "unsupported InfluxQL (#{unread(reason)} after a `;`)"}

          true ->
            {:error, {:engine, InfluxQLError.syntax_error_body(:nom, start, statement)}}
        end
    end
  end

  defp unread(:unread_order), do: "clauses the double does not read in that order"
  defp unread(:unread_shape), do: "that shape of statement"
  defp unread(message) when is_binary(message), do: message

  # The select list comes before every clause. A parse error of a clause stands only when the
  # list reads: one the double cannot read (`derivative(usage, )`, `-*`) may be an error of
  # the engine's before it, so the double refuses it, whatever a clause behind it holds.
  @spec readable_items_first(:ok | {:error, term()}, binary(), binary()) ::
          :ok | {:error, term()}
  defp readable_items_first({:error, {:engine, _body}} = error, items, masked_items) do
    with {:error, message} when is_binary(message) <- parse_items(items, masked_items),
         false <- engine_reads?(masked_items) do
      {:error, message}
    else
      _the_clause_error_stands -> error
    end
  end

  defp readable_items_first(result, _items, _masked_items), do: result

  # Whether every item reads as an expression for the engine, which the double only fails to
  # compute (`usage::field` is no parse error).
  @spec engine_reads?(binary()) :: boolean()
  defp engine_reads?(masked_items) do
    masked_items
    |> InfluxQLSelectCheck.comma_pieces(0)
    |> Enum.all?(fn {piece, _at} -> InfluxQLArgs.item?(piece) end)
  end

  # A form feed and a vertical tab are no blanks to the engine, and what it does with them
  # outside a literal is verified in one place only: the sign of a `fill()` number
  # (`fill(-\f1)` is an invalid option). The double reads them as blanks elsewhere, so it
  # refuses them there.
  @comparison InfluxElixir.Client.Local.InfluxQLBlankRegex.blank_pattern(
                ~S{(?:[A-Za-z_]\w*|"_*")\s*(?:=~|!~|!=|<>|<=|>=|=|<|>)\s*(?:'_*'|[-+]?\d+(?:\.\d+)?|/_*/)}
              )
  @after_condition InfluxElixir.Client.Local.InfluxQLBlankRegex.blank_pattern(
                     ~S{\bGROUP\s+BY\b|\bORDER\s+BY\b|\bLIMIT\b|\bOFFSET\b|\bSLIMIT\b|\bSOFFSET\b|\bfill\s*\(}
                   )

  @spec check_blanks(binary()) :: :ok | {:error, binary()}
  defp check_blanks(masked) do
    unverified = Regex.replace(~q/(fill\s*\(\s*[+-])[\x0b\x0c]/i, masked, "\\1")

    if String.contains?(unverified, ["\f", "\v"]) or
         (unverified != masked and not verified_condition?(masked)),
       do: {:error, "unsupported InfluxQL (a form feed or vertical tab outside a literal)"},
       else: :ok
  end

  # Whether the condition of the statement, if it has one, is plain comparisons of a name with
  # a constant joined by `AND`/`OR`: the engine reads them as the double does, so an error
  # that stands behind them is the one the engine meets.
  @spec verified_condition?(binary()) :: boolean()
  defp verified_condition?(masked) do
    case Regex.run(~q/\bWHERE\s+(.*?)\s*(?:#{@after_condition}|\z)/is, masked) do
      [_all, where] ->
        Regex.match?(~q/\A#{@comparison}(?:\s+(?:AND|OR)\s+#{@comparison})*\z/i, where)

      nil ->
        true
    end
  end

  @spec check_supported(binary()) :: :ok | {:error, binary()}
  defp check_supported(masked) do
    case Enum.find(unsupported(), fn {pattern, _name} -> Regex.match?(pattern, masked) end) do
      nil -> :ok
      {_pattern, name} -> {:error, "unsupported InfluxQL (#{name})"}
    end
  end

  # The named captures of `regex` run over `masked`, read from `text` (the
  # same length): a keyword inside a literal cannot end a clause early.
  @spec slices(Regex.t(), binary(), binary()) :: %{binary() => binary()} | nil
  defp slices(regex, masked, text) do
    with %{} = indexes <- Regex.named_captures(regex, masked, return: :index) do
      Map.new(indexes, fn {name, {from, length}} ->
        {name, if(from < 0, do: "", else: binary_part(text, from, length))}
      end)
    end
  end

  # The items of the select list, cut at the commas outside literals.
  @spec parse_items(binary(), binary()) :: {:ok, [InfluxQL.item()]} | {:error, binary()}
  defp parse_items(text, masked) do
    masked
    |> InfluxQLSelectCheck.comma_pieces(0)
    |> Enum.map(fn {piece, at} ->
      text |> binary_part(at, byte_size(piece)) |> InfluxQLLex.trim_both_blanks()
    end)
    |> Enum.reduce_while({:ok, []}, fn text, {:ok, acc} ->
      case parse_item(text) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  @spec parse_item(binary()) :: {:ok, InfluxQL.item()} | {:error, binary()}
  defp parse_item("*"), do: {:ok, :star}

  defp parse_item("*::" <> _kind = text) do
    case String.downcase(text) do
      "*::field" -> {:ok, {:wild_column, {:star, "field"}}}
      "*::tag" -> {:ok, {:wild_column, {:star, "tag"}}}
      _other -> unsupported_item(text, "a type after *:: other than field and tag")
    end
  end

  defp parse_item("/" <> _rest = text) do
    case Regex.run(~q/^\/((?:[^\/\\]|\\.)+)\/(?:\s*AS\s+(?:"[^"]+"|\w+))?$/is, text) do
      [_all, source] -> {:ok, {:wild_column, {:regex, String.replace(source, "\\/", "/")}}}
      nil -> unsupported_item(text, "a regular expression column in that shape")
    end
  end

  defp parse_item(text) do
    cond do
      Regex.match?(@literal, text) ->
        {:ok, {:literal, text}}

      captures = Regex.named_captures(@count_distinct, text) ->
        {:ok,
         {:aggregate, "count",
          {:distinct, InfluxQLText.unquote_ident(captures["arg"] <> captures["bare"])},
          InfluxQLText.blank_to_nil(InfluxQLText.unquote_ident(captures["alias"]))}}

      captures = Regex.named_captures(@function, text) ->
        function_item(captures, text)

      captures = Regex.named_captures(@column, text) ->
        {:ok, column_item(InfluxQLText.unquote_ident(captures["col"]), captures["alias"])}

      true ->
        expression_item(text)
    end
  end

  # Arithmetic over fields and aggregates, with its alias.
  @spec expression_item(binary()) :: {:ok, InfluxQL.item()} | {:error, binary()}
  defp expression_item(text) do
    case Regex.named_captures(~q/^(?<body>.+?)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is, text) do
      %{"body" => body, "alias" => alias} -> expression(InfluxQLExpr.parse(body), alias, text)
      nil -> unsupported_item(text, "an item with an alias in that shape")
    end
  end

  @spec expression(term(), binary(), binary()) :: {:ok, InfluxQL.item()} | {:error, binary()}
  defp expression(parsed, alias, text) do
    alias = InfluxQLText.blank_to_nil(InfluxQLText.unquote_ident(alias))

    case parsed do
      {:ok, {:agg, fun, field}} -> {:ok, {:aggregate, fun, field, alias}}
      {:ok, ast} -> {:ok, column_or_expression(ast, alias)}
      {:multi, kind, field, tags, limit} -> {:ok, {:multi, kind, field, tags, limit, alias}}
      {:wild, name, extra, target} -> {:ok, {:wild_call, name, extra, target, alias}}
      {:expand_error, message} -> {:ok, {:expand_error, message}}
      {:planning, message} -> {:ok, {:planning_error, message}}
      {:paren_constant, ast} -> {:ok, {:planning_error, @no_variable, ast}}
      {:argument, name, argument} -> {:ok, {:argument_error, name, argument}}
      _unread -> unsupported_item(text, unread_reason(text))
    end
  end

  # The refusal of a select item, with why: what the double does not read in it.
  @spec unsupported_item(binary(), binary()) :: {:error, binary()}
  defp unsupported_item(text, why), do: {:error, "unsupported InfluxQL (#{why}): #{text}"}

  # What of an expression the double does not read puts it outside the forms it knows, by the
  # first shape that fits.
  @spec unread_reason(binary()) :: binary()
  defp unread_reason(text) do
    cond do
      text =~ ~q/\A\s*\*\s+AS\b/i ->
        "an alias on *"

      text =~ ~q/\A\s*[+-]\s*(?:[+-]|true\b|false\b|')/i ->
        "a sign before a boolean, a string or a sign"

      text =~ ~q/\(\s*\(|,\s*\(/ ->
        "a parenthesised argument of a call"

      text =~ ~q/\)\s*::|\w\s*\([^()]*::/ ->
        "a cast inside or after a call"

      text =~ ~q/[=<>!]/ ->
        "a comparison in a select item"

      text =~ ~q/distinct\s*\(.*\)\s*[-+*\/%]/i ->
        "arithmetic on count(distinct())"

      text =~ ~q/\w\s*\(\s*\)/ ->
        "a call without arguments"

      text =~ ~q/\w\s*\([^()]*,[^()]*\)/ ->
        "a call with more arguments than it takes"

      text =~ ~q/\w\s*\(\s*(?:[-+]|\w+\s*\()/ ->
        "an expression as the argument of an aggregate"

      true ->
        "an expression of a form the double does not read"
    end
  end

  # A column in parentheses, or under a plus sign, is the column (verified: `(s)`, `((s))`,
  # `+s`, `(b)` and `(host)` answer a string, a boolean or a tag as `s`, `b` and `host`
  # do); anything else is arithmetic.
  @spec column_or_expression(term(), binary() | nil) :: InfluxQL.item()
  defp column_or_expression(ast, alias) do
    case ast do
      {:ref, name} ->
        if String.downcase(name) == "time",
          do: {:expr, ast, alias},
          else: {:column, name, alias || name}

      _other ->
        {:expr, ast, alias}
    end
  end

  # The one name a statement selects from, when it names one.
  @spec measurement_name([{:name | :regex, binary()}]) :: binary()
  defp measurement_name([{:name, name}]), do: name
  defp measurement_name(_sources), do: ""

  # The time column is named `time` unless it is aliased, whatever its case.
  @spec column_item(binary(), binary()) :: InfluxQL.item()
  defp column_item(column, alias) do
    default = if String.downcase(column) == "time", do: "time", else: column
    {:column, column, alias_or(alias, default)}
  end

  @spec function_item(map(), binary()) :: {:ok, InfluxQL.item()} | {:error, binary()}
  defp function_item(%{"fn" => fun, "arg" => arg, "alias" => alias}, text) do
    fun = String.downcase(fun)

    cond do
      fun not in @aggregates ->
        expression_item(text)

      arg == "*" and fun == "distinct" ->
        {:error, "unsupported InfluxQL (distinct(*))"}

      arg == "*" and fun != "count" ->
        {:ok,
         {:wild_call, fun, [], {:star, nil},
          InfluxQLText.blank_to_nil(InfluxQLText.unquote_ident(alias))}}

      arg == "*" ->
        {:ok,
         {:aggregate, fun, :star, InfluxQLText.blank_to_nil(InfluxQLText.unquote_ident(alias))}}

      true ->
        aggregate_item(fun, arg, alias, text)
    end
  end

  @spec aggregate_item(binary(), binary(), binary(), binary()) ::
          {:ok, InfluxQL.item()} | {:error, binary()}
  defp aggregate_item(fun, arg, alias, text) do
    alias = InfluxQLText.blank_to_nil(InfluxQLText.unquote_ident(alias))

    case InfluxQLLiteral.debug(arg) do
      {:ok, debug} -> {:ok, {:aggregate, fun, {:literal, debug}, alias}}
      {:error, message} -> {:error, "unsupported InfluxQL (#{message})"}
      :none -> signed_or_column(fun, arg, alias, text)
    end
  end

  # An argument that is a name, not a signed non-number.
  @spec signed_or_column(binary(), binary(), binary() | nil, binary()) ::
          {:ok, InfluxQL.item()} | {:error, binary()}
  defp signed_or_column(fun, arg, alias, text) do
    if String.starts_with?(arg, ["+", "-"]),
      do: unsupported_item(text, "a signed argument that is no number"),
      else: {:ok, {:aggregate, fun, InfluxQLText.unquote_ident(arg), alias}}
  end

  # What follows `FROM` does not read as clauses. A `fill()` after `ORDER BY`,
  # `LIMIT`, `OFFSET` or another `fill()` is left over from itself (verified);
  # one elsewhere that the grammar did not take is where the double does not
  # read it.
  @spec clauses_error(binary(), non_neg_integer(), {binary(), binary()}, binary()) ::
          InfluxQLCheck.positioned()
  defp clauses_error(whole, at, {masked_all, masked_rest}, rest) do
    case clause_error(whole, at, {masked_all, masked_rest}, rest) do
      {pos, {:error, :unread_order}} = unread ->
        if Regex.match?(~q/\bfill\s*\(/i, masked_rest),
          do: InfluxQLCheck.refuse(pos, "unsupported InfluxQL (fill() outside GROUP BY)"),
          else: unread

      error ->
        error
    end
  end

  # The first clause the engine's parser stops at: each clause keyword in turn is
  # read for its own error; when none has one, the clauses are in an order the
  # double does not read.
  @spec clause_error(binary(), non_neg_integer(), {binary(), binary()}, binary()) ::
          InfluxQLCheck.positioned()
  defp clause_error(whole, at, {masked_all, masked_rest}, rest) do
    blank = InfluxQLBlanks.clauses(whole, at, masked_all)

    if first_clause_error?(blank, at, masked_all) do
      blank
    else
      junk = InfluxQLClauseScan.junk(whole, at, masked_all)

      stop =
        InfluxQLCheck.condition_error(whole, at, masked_rest, rest) ||
          clauses_stop(whole, at, masked_rest)

      # What is left over is the engine's answer, where the double has only found clauses in
      # an order it does not read.
      stop = if junk != nil and match?({_pos, {:error, :unread_order}}, stop), do: nil, else: stop

      # A number past the unsigned range and a `fill()` option that does not read are met
      # where they stand, before what is left over behind them.
      InfluxQLCheck.leftmost([
        blank,
        junk,
        stop,
        InfluxQLCheck.check_unsigned(whole, at, masked_all),
        InfluxQLCheck.fill_error(whole, at, masked_all)
      ])
    end
  end

  # The engine's error at a keyword that stands first among the clauses (only blanks before
  # it) is the statement's whatever stands behind it: the parser stops there, so no clause
  # is out of its order and nothing else has been read.
  @spec first_clause_error?(InfluxQLCheck.positioned() | nil, non_neg_integer(), binary()) ::
          boolean()
  defp first_clause_error?({key, {:error, {:engine, _body}}}, at, masked_all) when key >= at do
    InfluxQLLex.trim_blanks(binary_part(masked_all, 0, key - at)) == ""
  end

  defp first_clause_error?(_blank, _at, _masked_all), do: false

  @spec clauses_stop(binary(), non_neg_integer(), binary()) :: InfluxQLCheck.positioned()
  defp clauses_stop(whole, at, masked_rest) do
    stop =
      ~q/\b(?:GROUP|ORDER|LIMIT|OFFSET|SLIMIT|SOFFSET)\b|(?<![\w])tz(?=\s*\()/i
      |> Regex.scan(masked_rest, return: :index)
      |> Enum.find_value(fn [{from, _size}] ->
        with true <- clause_position?(masked_rest, from),
             {_pos, {:error, reason}} = error when reason != :unread_order <-
               InfluxQLCheck.check_swallowed(whole, at, masked_rest, {from}) do
          error
        else
          _no_error_of_its_own -> nil
        end
      end)

    # A number past the unsigned range, and a `fill()` whose option does not read, stand before
    # the clause that does not read when they are the leftmost (`LIMIT 99999999999999999999
    # SLIMIT x` is the overflow, `fill(x) ORDER BY y` the option).
    case stop || out_of_order(whole, at, masked_rest) do
      {_pos, {:error, {:engine, _body}}} = stop ->
        InfluxQLCheck.leftmost([
          stop,
          InfluxQLCheck.check_unsigned(whole, at, masked_rest),
          InfluxQLCheck.fill_error(whole, at, masked_rest)
        ])

      refusal ->
        refusal
    end
  end

  # Where a `tz(` stands as the clause (after the complete operand or clause before it) and
  # not as a call in an operand's place.
  @spec clause_position?(binary(), non_neg_integer()) :: boolean()
  defp clause_position?(masked_rest, from) do
    rest = binary_part(masked_rest, from, byte_size(masked_rest) - from)

    if String.downcase(binary_part(rest, 0, 2)) == "tz" do
      before = InfluxQLLex.trim_trailing_blanks(binary_part(masked_rest, 0, from))

      before =~ ~q/[\w'")]\z/ and
        not (before =~ ~q/(?<![\w])(?:WHERE|BY|AND|OR)\z/i) and
        not (before =~ InfluxQLText.open_operand())
    else
      true
    end
  end

  # The clauses come in one order (`InfluxQLText.clause_ranks/0`): what follows the last the
  # parser could read is left over from where the first clause that is out of its place starts.
  @spec out_of_order(binary(), non_neg_integer(), binary()) :: InfluxQLCheck.positioned()
  defp out_of_order(whole, at, masked_rest) do
    ~q/(?<![\w])(WHERE|GROUP\s+BY|fill\s*\(|ORDER\s+BY|LIMIT|OFFSET|SLIMIT|SOFFSET|TZ\s*\()/i
    |> Regex.scan(masked_rest, return: :index, capture: :all_but_first)
    |> Enum.reduce_while({-1, nil, []}, fn [{from, size}], {highest, last_from, tzs} ->
      word = masked_rest |> binary_part(from, size) |> String.downcase() |> clause_word()
      rank = Map.fetch!(InfluxQLText.clause_ranks(), word)
      tzs = if word == "tz", do: [from | tzs], else: tzs

      if rank > highest,
        do: {:cont, {rank, from, tzs}},
        else:
          {:halt, {:out_of_place, out_of_place(whole, at, from, last_from, tl_after(tzs, word))}}
    end)
    |> case do
      {:out_of_place, positioned} -> positioned
      _in_order -> InfluxQLCheck.unread()
    end
  end

  # The clause that stands out of its place is left over from where it starts. After a `tz()`
  # of a zone other than `UTC` the engine reads the zone first and fails on one it does not
  # know, which the double cannot tell from one it does: refused. A `tz(` the engine cannot read
  # as a clause (`tz('UTC'!`) is no clause: the statement is left over from it.
  defp out_of_place(whole, at, from, last_from, tzs) do
    cond do
      unknown = tzs |> Enum.reverse() |> Enum.find(&InfluxQLCheck.unknown_zone?(whole, at + &1)) ->
        InfluxQLCheck.refuse_zone(at + unknown)

      last_from != nil and InfluxQLCheck.broken_tz?(whole, at + last_from) ->
        InfluxQLCheck.fail(:nom, at + last_from, whole)

      true ->
        InfluxQLCheck.fail(:nom, at + from, whole)
    end
  end

  # The `tz` clauses read before the one that is out of place: the out of place one is itself
  # left over, never read.
  defp tl_after([_current | read], "tz"), do: read
  defp tl_after(read, _word), do: read

  defp clause_word(text), do: text |> String.split(~q/[\s(]/, parts: 2) |> hd()

  # The option of the `fill()` the statement has, `nil` for none.
  @spec fill_option(map()) :: binary() | nil
  defp fill_option(%{"fillcall" => ""}), do: nil
  defp fill_option(%{"fill" => option}), do: option

  # `tz('UTC')` changes nothing (the times are written in UTC anyway); another
  # zone writes the times with its offset and aligns the buckets of a `GROUP BY
  # time` to its days, which needs a time zone database the double does not
  # carry.
  @spec check_tz(map()) :: :ok | {:error, binary()}
  defp check_tz(%{"tzcall" => ""}), do: :ok
  defp check_tz(%{"tz" => "UTC"}), do: :ok
  defp check_tz(%{"tz" => zone}), do: {:error, "unsupported InfluxQL (tz('#{zone}'))"}

  # A condition the double does not read is refused before the statement-level answers that
  # stand behind it (`SLIMIT` is the engine's 405 only if the condition is valid: `x.y < 1 <=
  # SLIMIT 1` is its conditional-expression error). A condition that is only unread for its
  # dotted names is read with them as plain names: if that reads, the later stages have it.
  @spec where_refusal(binary() | nil) :: :ok | {:error, binary()}
  defp where_refusal(nil), do: :ok

  defp where_refusal(where) do
    with {:error, message} when is_binary(message) <- InfluxQLTokens.tokenize(where, []),
         plain = Regex.replace(~q/(?<=[\w"])\.(?=[A-Za-z_"])/, where, "_"),
         true <- plain != where,
         false <- match?({:ok, _tokens}, InfluxQLTokens.tokenize(plain, [])) do
      {:error, message}
    else
      _read_or_syntax_error -> :ok
    end
  end

  # `SLIMIT` and `SOFFSET` read, then the engine's planner says it has no such
  # feature, whatever the measurement.
  @spec not_implemented(map()) :: :ok | {:error, {:engine, pos_integer(), binary()}}
  defp not_implemented(%{"slimit" => "", "soffset" => ""}), do: :ok

  defp not_implemented(_clauses),
    do:
      {:error,
       {:engine, 405,
        InfluxQLError.rewrite_error("This feature is not implemented: SLIMIT or SOFFSET")}}

  @spec group_error(term()) :: InfluxQLCheck.positioned() | nil
  defp group_error({:error, {:engine, body, key}}), do: {key, {:error, {:engine, body}}}
  defp group_error({:error, message}), do: InfluxQLCheck.refuse(0, message)
  defp group_error(_result), do: nil

  # The clause as `InfluxQLGroup` read it; without one in its place the text
  # may still hold a `fill()` (read, and changing nothing).
  @spec group_of(term(), map()) :: {:ok, InfluxQLGroup.t()} | {:error, binary()}
  defp group_of({:ok, group}, _clauses), do: {:ok, group}

  defp group_of(:none, %{"group" => ""} = clauses) do
    with {:ok, fill} <- InfluxQLGroup.parse_loose_fill(fill_option(clauses)),
         do: {:ok, %{dimensions: [], time: nil, fill: fill}}
  end

  defp group_of(:none, _clauses), do: {:error, "unsupported InfluxQL (that GROUP BY clause)"}

  @spec alias_or(binary(), binary()) :: binary()
  defp alias_or("", column), do: column
  defp alias_or(alias, _column), do: InfluxQLText.unquote_ident(alias)

  @spec to_int(binary()) :: non_neg_integer() | nil
  defp to_int(""), do: nil
  defp to_int(digits), do: String.to_integer(digits)
end
