defmodule InfluxElixir.Client.Local.InfluxQLParser do
  @moduledoc false
  # Reads an InfluxQL `SELECT` into the query map `InfluxElixir.Client.Local.InfluxQL`
  # shapes and plans: the clauses are located on a mask of the statement (so a
  # keyword inside a literal is no keyword), checked as the engine's parser
  # checks them (`InfluxElixir.Client.Local.InfluxQLCheck`), and a statement after
  # a `;` is read the same way.

  alias InfluxElixir.Client.Local.{
    InfluxQL,
    InfluxQLCheck,
    InfluxQLError,
    InfluxQLExpr,
    InfluxQLGroup,
    InfluxQLLiteral,
    InfluxQLNames,
    InfluxQLSelectCheck,
    InfluxQLText
  }

  @aggregates ~w(mean sum count min max first last median spread stddev distinct)

  # Regexes nested in a list cannot be module attributes on OTP 28, so the
  # table is a function.
  @spec unsupported() :: [{Regex.t(), binary()}]
  defp unsupported do
    [
      {~r/\bINTO\b/i, "INTO"},
      {~r/\bFROM\s*\(/i, "subqueries"}
    ]
  end

  @source ~S{"(?:[^"\\]|\\.)+"|/(?:[^/\\]|\\.)+/|[A-Za-z_][\w\-]*}
  @select Regex.compile!(
            "^\\s*SELECT\\s+(?<items>.+?)\\s+FROM\\s+" <>
              "(?<from>(?:#{@source})(?:\\s*,\\s*(?:#{@source}))*)(?<rest>.*)$",
            "is"
          )

  @function ~r/^(?<fn>[A-Za-z_]\w*)\s*\(\s*(?<arg>\*|"[^"]+"|'(?:[^'\\]|\\.)*'|[+-]?[\w.]+)\s*\)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is
  @literal ~r/^(?:'(?:[^'\\]|\\.)*'|[+-]?(?:\d+\.\d+|\.\d+|\d+)|(?:\d+(?:ns|ms|u|µ|s|m|h|d|w))+|true|false)(?:\s+AS\s+(?:"[^"]+"|\w+))?$/isu
  @count_distinct ~r/^count\s*\(\s*distinct(?:\s*\(\s*(?<arg>"[^"]+"|[A-Za-z_][\w.]*)\s*\)|\s+(?<bare>"[^"]+"|[A-Za-z_][\w.]*))\s*\)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is
  @column ~r/^(?<col>"[^"]+"|[\w.]+)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is

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
           Regex.run(~r/Nom\((".*"), (?:Tag|Char)\)$/s, body, return: :index),
         quoted = binary_part(body, at, length),
         size = byte_size(clean),
         from when from != nil <-
           Enum.find(0..size, &(inspect(binary_part(clean, &1, size - &1)) == quoted)) do
      binary_part(body, 0, at) <>
        inspect(binary_part(statement, from, size - from)) <>
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

    with :ok <- check_comment(unclosed, clean),
         :ok <- InfluxQLCheck.check_literals(clean),
         :ok <- check_supported(masked_head),
         :ok <- InfluxQLSelectCheck.check_select(clean, masked_head),
         %{"items" => items, "from" => from, "rest" => rest} <-
           slices(@select, masked_head, head) || {:error, :unread_shape},
         %{"items" => masked_items, "rest" => masked_rest} =
           slices(@select, masked_head, masked_head),
         at = byte_size(head) - byte_size(rest),
         :ok <- InfluxQLCheck.check_empty_where(clean, at, masked_rest),
         {group_result, masked_rest} = InfluxQLGroup.extract(clean, at, masked_rest),
         %{} = clauses <-
           slices(InfluxQLText.clauses(), masked_rest, rest) ||
             clauses_error(clean, at, masked_rest),
         {where, swallowed} = InfluxQLCheck.cut_where(masked_rest, clauses["where"]),
         :ok <- InfluxQLCheck.check_where(clean, at, masked_rest, where),
         :ok <- group_error(group_result),
         :ok <- InfluxQLCheck.check_group(clean, at, masked_rest),
         :ok <- InfluxQLCheck.check_swallowed(clean, at, masked_rest, swallowed),
         :ok <- InfluxQLCheck.check_unsigned(clean, at, masked_rest),
         :ok <- InfluxQLCheck.check_fill(clean, at, masked_rest),
         {:ok, group} <- group_of(group_result, clauses),
         {:ok, items} <- parse_items(items, masked_items),
         {:ok, items} <- InfluxQLNames.resolve(items),
         :ok <- check_tz(clauses),
         :ok <- not_implemented(clauses),
         :ok <- check_single(statement, tail) do
      {:ok,
       %{
         items: items,
         measurement: from |> sources() |> measurement_name(),
         sources: sources(from),
         where: where,
         group_by: group.dimensions,
         group_time: group.time,
         fill: group.fill || :null,
         descending: String.upcase(clauses["dir"]) == "DESC",
         limit: to_int(clauses["limit"]),
         offset: to_int(clauses["offset"]) || 0,
         rewrite_error: Map.get(group, :rewrite_error)
       }}
    end
  end

  # A `--` outside a literal comments out the rest of its line, `/* ... */`
  # (not nested) comments out what it holds. The comment becomes spaces, byte
  # for byte, in the statement and its mask, so every offset stays the
  # engine's. A `/*` never closed is the lexer's error at the `*` (verified),
  # returned as its position.
  @comments ~r/--[^\n]*|\/\*.*?\*\/|\/\*/s

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

  # The slash that closes `=~ /re/` is not the start of a comment.
  @spec regex_closing?({non_neg_integer(), non_neg_integer()}, binary()) :: boolean()
  defp regex_closing?({at, _size}, masked) when at > 0 do
    binary_part(masked, at, 2) == "/*" and
      binary_part(masked, 0, at) =~ ~r/[=!]~\s*\/_*$/
  end

  defp regex_closing?(_comment, _masked), do: false

  @spec check_comment(non_neg_integer() | nil, binary()) :: :ok | {:error, {:engine, binary()}}
  defp check_comment(nil, _statement), do: :ok

  defp check_comment(at, statement),
    do: {:error, {:engine, InfluxQLError.syntax_error_body(:comment, at, statement)}}

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
    [skipped] = Regex.run(~r/^[\s;]*/, clean_rest)
    start = after_semicolon + byte_size(skipped)

    case binary_part(statement, start, byte_size(statement) - start) do
      "" -> :ok
      next -> next_statement_error(statement, next, start)
    end
  end

  @only_one "must provide only one InfluxQl statement per query"
  @other_statements ~r/^SHOW\s+(?:DATABASES|MEASUREMENTS|TAG\s+(?:KEYS|VALUES)|FIELD\s+KEYS)\b/i

  # Statements the engine reads in ways the double does not follow; any
  # other text is not a statement at all, and the engine fails it where it
  # starts (verified).
  @known_statements ~r/^(?:(?:SELECT|SHOW|EXPLAIN|CREATE|DELETE)(?![\w])|DROP(?![\w])\s*\S)/i

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
    |> Enum.map(fn {piece, at} -> text |> binary_part(at, byte_size(piece)) |> String.trim() end)
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
      _other -> {:error, "unsupported select item: #{text}"}
    end
  end

  defp parse_item("/" <> _rest = text) do
    case Regex.run(~r/^\/((?:[^\/\\]|\\.)+)\/(?:\s+AS\s+(?:"[^"]+"|\w+))?$/is, text) do
      [_all, source] -> {:ok, {:wild_column, {:regex, String.replace(source, "\\/", "/")}}}
      nil -> {:error, "unsupported select item: #{text}"}
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
    case Regex.named_captures(~r/^(?<body>.+?)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is, text) do
      %{"body" => body, "alias" => alias} -> expression(InfluxQLExpr.parse(body), alias, text)
      nil -> {:error, "unsupported select item: #{text}"}
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
      {:argument, name, argument} -> {:ok, {:argument_error, name, argument}}
      _unread -> {:error, "unsupported select item: #{text}"}
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

  # The measurements `FROM` names: names and regular expressions, in order.
  @spec sources(binary()) :: [{:name, binary()} | {:regex, binary()}]
  defp sources(from) do
    ~r/"(?:[^"\\]|\\.)+"|\/(?:[^\/\\]|\\.)+\/|[A-Za-z_][\w\-]*/
    |> Regex.scan(from)
    |> Enum.map(fn
      ["/" <> _body = regex] ->
        {:regex, regex |> String.slice(1..-2//1) |> String.replace("\\/", "/")}

      [name] ->
        {:name, InfluxQLText.unquote_ident(name)}
    end)
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
      do: {:error, "unsupported select item: #{text}"},
      else: {:ok, {:aggregate, fun, InfluxQLText.unquote_ident(arg), alias}}
  end

  # What follows `FROM` does not read as clauses. A `fill()` after `ORDER BY`,
  # `LIMIT`, `OFFSET` or another `fill()` is left over from itself (verified);
  # one elsewhere that the grammar did not take is where the double does not
  # read it.
  @spec clauses_error(binary(), non_neg_integer(), binary()) :: {:error, term()}
  defp clauses_error(whole, at, masked_rest) do
    fills = Regex.scan(~r/\bfill\s*\(/i, masked_rest, return: :index)

    case fills do
      [] ->
        clause_error(whole, at, masked_rest)

      [[{fill_at, _size}]] ->
        if Regex.match?(
             ~r/\b(?:ORDER\s+BY|LIMIT|OFFSET)\b/i,
             binary_part(masked_rest, 0, fill_at)
           ),
           do: {:error, {:engine, InfluxQLError.syntax_error_body(:nom, at + fill_at, whole)}},
           else: {:error, "unsupported InfluxQL (fill() outside GROUP BY)"}

      [_first, [{second_at, _size}] | _more] ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:nom, at + second_at, whole)}}
    end
  end

  # The first clause the engine's parser stops at: each clause keyword in turn is
  # read for its own error; when none has one, the clauses are in an order the
  # double does not read.
  @spec clause_error(binary(), non_neg_integer(), binary()) :: {:error, term()}
  defp clause_error(whole, at, masked_rest) do
    ~r/\b(?:GROUP|ORDER|LIMIT|OFFSET|SLIMIT|SOFFSET)\b/i
    |> Regex.scan(masked_rest, return: :index)
    |> Enum.find_value({:error, :unread_order}, fn [{from, _size}] ->
      case InfluxQLCheck.check_swallowed(whole, at, masked_rest, {from}) do
        {:error, {:engine, _body}} = error -> error
        _no_error_of_its_own -> nil
      end
    end)
  end

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

  # `SLIMIT` and `SOFFSET` read, then the engine's planner says it has no such
  # feature, whatever the measurement.
  @spec not_implemented(map()) :: :ok | {:error, {:engine, pos_integer(), binary()}}
  defp not_implemented(%{"slimit" => "", "soffset" => ""}), do: :ok

  defp not_implemented(_clauses),
    do:
      {:error,
       {:engine, 405,
        InfluxQLError.rewrite_error("This feature is not implemented: SLIMIT or SOFFSET")}}

  @spec group_error(term()) ::
          :ok | {:error, term()}
  defp group_error({:error, _error} = error), do: error
  defp group_error(_result), do: :ok

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
