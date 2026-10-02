defmodule InfluxElixir.Client.Local.InfluxQLParser do
  @moduledoc """
  Reads an InfluxQL `SELECT` into the query map `InfluxElixir.Client.Local.InfluxQL`
  shapes and plans: the clauses are located on a mask of the statement (so a
  keyword inside a literal is no keyword), checked as the engine's parser
  checks them (`InfluxElixir.Client.Local.InfluxQLCheck`), and a statement after
  a `;` is read the same way.
  """

  alias InfluxElixir.Client.Local.{
    InfluxQL,
    InfluxQLCheck,
    InfluxQLError,
    InfluxQLLiteral,
    InfluxQLNames,
    InfluxQLSelectCheck,
    SQLMask
  }

  @aggregates ~w(mean sum count min max first last)
  @selectors ~w(min max first last)

  # Regexes nested in a list cannot be module attributes on OTP 28, so the
  # table is a function.
  @spec unsupported() :: [{Regex.t(), binary()}]
  defp unsupported do
    [
      {~r/\bfill\s*\(/i, "fill()"},
      {~r/\bINTO\b/i, "INTO"},
      {~r/\bS(?:LIMIT|OFFSET)\b/i, "SLIMIT/SOFFSET"},
      {~r/\bFROM\s*\(/i, "subqueries"},
      {~r/\bGROUP\s+BY\b.*\btime\s*\(/is, "GROUP BY time(...)"},
      {~r/\bGROUP\s+BY\s+\*/i, "GROUP BY *"},
      {~r/\btz\s*\(/i, "tz()"}
    ]
  end

  @select ~r/^\s*SELECT\s+(?<items>.+?)\s+FROM\s+(?<from>"(?:[^"\\]|\\.)+"|[A-Za-z_][\w\-]*)(?<rest>.*)$/is

  @rest ~r/^\s*(?:WHERE\s+(?<where>.+?))?\s*(?:GROUP\s+BY\s+(?<group>.+?))?\s*(?:ORDER\s+BY\s+(?:time\s+(?=ASC|DESC)|(?=ASC\b|DESC\b)|time\b)(?<dir>ASC|DESC)?)?\s*(?:LIMIT\s+(?<limit>\d+))?\s*(?:OFFSET\s+(?<offset>\d+))?\s*;?\s*$/is

  @doc false
  @spec rest() :: Regex.t()
  def rest, do: @rest

  @function ~r/^(?<fn>[A-Za-z_]\w*)\s*\(\s*(?<arg>\*|"[^"]+"|'(?:[^'\\]|\\.)*'|[+-]?[\w.]+)\s*\)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is
  @literal ~r/^(?:'(?:[^'\\]|\\.)*'|[+-]?(?:\d+\.\d+|\.\d+|\d+)|\d+(?:ns|ms|u|µ|s|m|h|d|w)|true|false)(?:\s+AS\s+(?:"[^"]+"|\w+))?$/isu
  @column ~r/^(?<col>"[^"]+"|[\w.]+)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is

  @doc """
  Parses an InfluxQL `SELECT`. Returns `{:error, message}` for syntax the
  engine rejects and for the constructs listed in the moduledoc.
  """
  @spec parse(binary()) :: {:ok, InfluxQL.query()} | {:error, binary() | {:engine, binary()}}
  def parse(statement) do
    {clean, masked} = blank_comments(statement, mask_literals(statement))
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
         %{} = clauses <- slices(@rest, masked_rest, rest) || {:error, "invalid clauses"},
         {where, swallowed} = InfluxQLCheck.cut_where(masked_rest, clauses["where"]),
         :ok <- InfluxQLCheck.check_where(clean, at, masked_rest, where),
         :ok <- InfluxQLCheck.check_group(clean, at, masked_rest),
         :ok <- InfluxQLCheck.check_swallowed(clean, at, masked_rest, swallowed),
         :ok <- InfluxQLCheck.check_unsigned(clean, at, masked_rest),
         :ok <- check_group_time(clauses["group"]),
         {:ok, items} <- parse_items(items, masked_items),
         :ok <- check_mix(items),
         {:ok, items} <- InfluxQLNames.resolve(items),
         :ok <- check_single(statement, tail) do
      {:ok,
       %{
         items: items,
         measurement: unquote_ident(from),
         where: where,
         group_by: parse_group(clauses["group"]),
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
    {clean_rest, _masked} = blank_comments(rest, mask_literals(rest))
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

  # The statement with the inside of every quoted string, quoted identifier
  # and `=~ /regex/` blanked to underscores, byte for byte (spaces would let
  # the clause regexes backtrack for ages), so that what is
  # looked for in it (`fill(`, `INTO`, `GROUP BY`) is a keyword and not a
  # piece of a value.
  @spec mask_literals(binary()) :: binary()
  @doc false
  def mask_literals(statement) do
    SQLMask.mask(statement,
      blank: ?_,
      doubled: false,
      backslash: true,
      regex: true,
      lenient: true
    )
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

      captures = Regex.named_captures(@function, text) ->
        function_item(captures, text)

      captures = Regex.named_captures(@column, text) ->
        {:ok, column_item(unquote_ident(captures["col"]), captures["alias"])}

      true ->
        {:error, "unsupported select item: #{text}"}
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
      fun not in @aggregates -> {:error, "unsupported InfluxQL function: #{text}"}
      arg == "*" and fun != "count" -> {:error, "unsupported InfluxQL (#{fun}(*))"}
      arg == "*" -> {:ok, {:aggregate, fun, :star, blank_to_nil(unquote_ident(alias))}}
      true -> aggregate_item(fun, arg, alias, text)
    end
  end

  @spec aggregate_item(binary(), binary(), binary(), binary()) ::
          {:ok, InfluxQL.item()} | {:error, binary()}
  defp aggregate_item(fun, arg, alias, text) do
    alias = blank_to_nil(unquote_ident(alias))

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
      else: {:ok, {:aggregate, fun, unquote_ident(arg), alias}}
  end

  # Plain columns beside aggregates take their values from the selected
  # point, so only a single selector can carry them.
  @spec check_mix([InfluxQL.item()]) :: :ok | {:error, binary()}
  defp check_mix(items) do
    if Enum.any?(items, &InfluxQLLiteral.literal_item?/1),
      do: :ok,
      else: check_columns_beside_aggregates(items)
  end

  @spec check_columns_beside_aggregates([InfluxQL.item()]) :: :ok | {:error, binary()}
  defp check_columns_beside_aggregates(items) do
    aggregates = for {:aggregate, _fn, _arg, _alias} = item <- items, do: item
    plain = Enum.reject(items, &match?({:aggregate, _fn, _arg, _alias}, &1))

    case {aggregates, plain} do
      {[], _plain} ->
        :ok

      {_aggregates, []} ->
        :ok

      {[{:aggregate, fun, arg, _alias}], _plain} when fun in @selectors and arg != :star ->
        :ok

      _mixed ->
        {:error, "unsupported InfluxQL (columns beside aggregates other than one selector)"}
    end
  end

  @spec parse_group(binary()) :: [binary()]
  defp parse_group(""), do: []

  defp parse_group(text) do
    text |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> unquote_ident()))
  end

  # A tag named `time` (`GROUP BY "time"`, `time::tag`) is a column of its own
  # next to the time column; the double does not reproduce that.
  @spec check_group_time(binary()) :: :ok | {:error, binary()}
  defp check_group_time(text) do
    if Regex.match?(~r/(?:^|,)\s*(?:"time"|time\s*::)/i, text),
      do: {:error, "unsupported InfluxQL (GROUP BY a tag named time)"},
      else: :ok
  end

  @spec unquote_ident(binary()) :: binary()
  @doc false
  def unquote_ident("\"" <> _rest = quoted),
    do: quoted |> String.trim("\"") |> String.replace("\\\"", "\"")

  def unquote_ident(ident), do: ident

  @spec alias_or(binary(), binary()) :: binary()
  defp alias_or("", column), do: column
  defp alias_or(alias, _column), do: unquote_ident(alias)

  @spec blank_to_nil(binary()) :: binary() | nil
  @doc false
  def blank_to_nil(""), do: nil
  def blank_to_nil(text), do: String.trim(text)

  @spec to_int(binary()) :: non_neg_integer() | nil
  defp to_int(""), do: nil
  defp to_int(digits), do: String.to_integer(digits)
end
