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
      {~r/\bS(?:LIMIT|OFFSET)\b/i, "SLIMIT/SOFFSET"},
      {~r/\bFROM\s*\(/i, "subqueries"},
      {~r/\bGROUP\s+BY\s+\*/i, "GROUP BY *"},
      {~r/\btz\s*\(/i, "tz()"}
    ]
  end

  @select ~r/^\s*SELECT\s+(?<items>.+?)\s+FROM\s+(?<from>"(?:[^"\\]|\\.)+"|[A-Za-z_][\w\-]*)(?<rest>.*)$/is

  @function ~r/^(?<fn>[A-Za-z_]\w*)\s*\(\s*(?<arg>\*|"[^"]+"|'(?:[^'\\]|\\.)*'|[+-]?[\w.]+)\s*\)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is
  @literal ~r/^(?:'(?:[^'\\]|\\.)*'|[+-]?(?:\d+\.\d+|\.\d+|\d+)|\d+(?:ns|ms|u|µ|s|m|h|d|w)|true|false)(?:\s+AS\s+(?:"[^"]+"|\w+))?$/isu
  @count_distinct ~r/^count\s*\(\s*distinct\s*\(\s*(?<arg>"[^"]+"|[A-Za-z_][\w.]*)\s*\)\s*\)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is
  @column ~r/^(?<col>"[^"]+"|[\w.]+)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is

  @doc """
  Parses an InfluxQL `SELECT`. Returns `{:error, message}` for syntax the
  engine rejects and for the constructs listed in the moduledoc.
  """
  @spec parse(binary()) :: {:ok, InfluxQL.query()} | {:error, binary() | {:engine, binary()}}
  def parse(statement) do
    {clean, masked} = blank_comments(statement, InfluxQLText.mask_literals(statement))
    {head, masked_head, tail} = split_statement(clean, masked)

    with :ok <- InfluxQLCheck.check_literals(clean),
         :ok <- check_supported(masked_head),
         :ok <- InfluxQLSelectCheck.check_select(clean, masked_head),
         %{"items" => items, "from" => from, "rest" => rest} <-
           slices(@select, masked_head, head) || {:error, "invalid statement"},
         %{"items" => masked_items, "rest" => masked_rest} =
           slices(@select, masked_head, masked_head),
         at = byte_size(head) - byte_size(rest),
         :ok <- InfluxQLCheck.check_empty_where(clean, at, masked_rest),
         %{} = clauses <-
           slices(InfluxQLText.clauses(), masked_rest, rest) ||
             clauses_error(clean, at, masked_rest),
         {where, swallowed} = InfluxQLCheck.cut_where(masked_rest, clauses["where"]),
         :ok <- InfluxQLCheck.check_where(clean, at, masked_rest, where),
         :ok <- InfluxQLCheck.check_group(clean, at, masked_rest),
         :ok <- InfluxQLCheck.check_swallowed(clean, at, masked_rest, swallowed),
         :ok <- InfluxQLCheck.check_unsigned(clean, at, masked_rest),
         :ok <- check_group_time(clauses["group"]),
         :ok <- InfluxQLCheck.check_fill(clean, at, masked_rest),
         {:ok, group} <- InfluxQLGroup.parse(clauses["group"], fill_option(clauses)),
         {:ok, items} <- parse_items(items, masked_items),
         {:ok, items} <- InfluxQLNames.resolve(items),
         :ok <- check_single(statement, tail) do
      {:ok,
       %{
         items: items,
         measurement: InfluxQLText.unquote_ident(from),
         where: where,
         group_by: group.tags,
         group_time: group.time,
         fill: group.fill || :null,
         descending: String.upcase(clauses["dir"]) == "DESC",
         limit: to_int(clauses["limit"]),
         offset: to_int(clauses["offset"]) || 0
       }}
    end
  end

  # A `--` outside a literal comments out the rest of its line. The comment
  # becomes spaces, byte for byte, in the statement and its mask, so every
  # offset stays the engine's.
  @spec blank_comments(binary(), binary()) :: {binary(), binary()}
  defp blank_comments(statement, masked) do
    comments = ~r/--[^\n]*/ |> Regex.scan(masked, return: :index) |> List.flatten()
    {Enum.reduce(comments, statement, &blank/2), Enum.reduce(comments, masked, &blank/2)}
  end

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
    {clean_rest, _masked} = blank_comments(rest, InfluxQLText.mask_literals(rest))
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
    case parse(next) do
      {:ok, _query} ->
        {:error, {:engine, @only_one}}

      {:error, {:engine, body}} ->
        {:error, {:engine, InfluxQLError.shift_position(body, start)}}

      {:error, "unsupported" <> _rest} = refusal ->
        refusal

      {:error, message} ->
        cond do
          Regex.match?(@other_statements, next) ->
            {:error, {:engine, @only_one}}

          Regex.match?(@known_statements, next) ->
            {:error, "#{message} (in a statement after `;`)"}

          true ->
            {:error, {:engine, InfluxQLError.syntax_error_body(:nom, start, statement)}}
        end
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

  defp parse_item(text) do
    cond do
      Regex.match?(@literal, text) ->
        {:ok, {:literal, text}}

      captures = Regex.named_captures(@count_distinct, text) ->
        {:ok,
         {:aggregate, "count", {:distinct, InfluxQLText.unquote_ident(captures["arg"])},
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
    with %{"body" => body, "alias" => alias} <-
           Regex.named_captures(~r/^(?<body>.+?)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is, text),
         {:ok, ast} <- InfluxQLExpr.parse(body) do
      {:ok, {:expr, ast, InfluxQLText.blank_to_nil(InfluxQLText.unquote_ident(alias))}}
    else
      _unread -> {:error, "unsupported select item: #{text}"}
    end
  end

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
        {:error, "unsupported InfluxQL function: #{text}"}

      arg == "*" and fun != "count" ->
        {:error, "unsupported InfluxQL (#{fun}(*))"}

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
        {:error, "invalid clauses"}

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

  # The option of the `fill()` the statement has, `nil` for none.
  @spec fill_option(map()) :: binary() | nil
  defp fill_option(%{"fillcall" => ""}), do: nil
  defp fill_option(%{"fill" => option}), do: option

  # A tag named `time` (`GROUP BY "time"`, `time::tag`) is a column of its own
  # next to the time column; the double does not reproduce that.
  @spec check_group_time(binary()) :: :ok | {:error, binary()}
  defp check_group_time(text) do
    if Regex.match?(~r/(?:^|,)\s*(?:"time"|time\s*::)/i, text),
      do: {:error, "unsupported InfluxQL (GROUP BY a tag named time)"},
      else: :ok
  end

  @spec alias_or(binary(), binary()) :: binary()
  defp alias_or("", column), do: column
  defp alias_or(alias, _column), do: InfluxQLText.unquote_ident(alias)

  @spec to_int(binary()) :: non_neg_integer() | nil
  defp to_int(""), do: nil
  defp to_int(digits), do: String.to_integer(digits)
end
