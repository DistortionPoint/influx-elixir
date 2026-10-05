defmodule InfluxElixir.Client.Local.SQLLimit do
  @moduledoc false
  # `LIMIT n` and `OFFSET m`, in either order, end a statement. A clause is the
  # keyword followed by a value, so a column called `offset` (an operator or
  # keyword follows it) stays a column. The engine's answers (verified): a name
  # is its schema error (500), a number with a fraction, a string or a boolean
  # the type_coercion error naming the clause and the type, a negative number
  # the optimizer's error, 0 and NULL are fine. Planning comes before
  # optimizing, and LIMIT before OFFSET; a negative OFFSET is reported by
  # `push_down_limit` when a LIMIT is present and by `eliminate_limit` when it
  # is not. A `$name` is checked the same way once
  # `InfluxElixir.Client.Local.SQLBind` knows its value.

  alias InfluxElixir.Client.Local.{SQLError, SQLLimits, SQLMask}

  require SQLLimits

  @int64_max SQLLimits.int64_max()
  @uint64_max SQLLimits.uint64_max()

  @typedoc "A LIMIT or OFFSET as the parser keeps it: a count, a `$name` or none."
  @type clause :: non_neg_integer() | {:param, binary()} | nil

  # What starts a LIMIT or OFFSET clause (rather than a column of that name):
  # a number, or NULL. A name after them is the engine's schema error, a
  # negative or fractional number its own, all answered by `check/2`.
  @start "(?:LIMIT|OFFSET)\\s+(?:-?\\.?[0-9]|NULL\\b|\\$)"

  @limit_keywords ~w(ASC DESC NULLS LIMIT OFFSET AND OR NOT IS IN LIKE ILIKE BETWEEN AS)

  @typep token ::
           {:count, non_neg_integer()}
           | {:wide, non_neg_integer()}
           | {:negative, binary()}
           | {:name, binary()}
           | {:type, binary()}
           | {:param, binary()}
           | :null
           | :other
           | :not_a_clause

  @doc "The source of a regular expression for what starts a LIMIT or OFFSET clause."
  @spec start_source() :: binary()
  def start_source, do: @start

  @doc """
  Checks that the LIMIT and OFFSET clauses of the text after the table are
  ones the double reads; `sql` is the statement, for a refusal. What the
  engine's planner finds wrong with them is `planning_error/1`, what its
  optimizer finds is `deferred/1`: both come after the errors of the clauses
  before them.
  """
  @spec check(binary(), binary()) :: :ok | {:error, SQLError.t()}
  def check(rest, sql) do
    {found, clauses} = scan(rest)
    refusal(clauses, trailing_garbage?(found, rest), sql)
  end

  @doc """
  The planner's error for a LIMIT or OFFSET of the text after the table that
  is a name or a fraction, or `nil`.
  """
  @spec planning_error(binary()) :: SQLError.t() | nil
  def planning_error(rest) do
    {_found, clauses} = scan(rest)
    error(planning(clauses))
  end

  @doc """
  The optimizer's error for a negative LIMIT or OFFSET of the text after the
  table, or `nil`. The optimizer finds it after `simplify_expressions` has
  folded the `WHERE`, so a `time` string it cannot read is reported first.
  """
  @spec deferred(binary()) :: SQLError.t() | nil
  def deferred(rest) do
    {_found, clauses} = scan(rest)
    error(optimizer(clauses))
  end

  @spec scan(binary()) :: {[{non_neg_integer(), {binary(), token()}}], [{binary(), token()}]}
  defp scan(rest) do
    found =
      ~r/(?i)(?<![\w.])(LIMIT|OFFSET)\s+(\S+)/u
      |> Regex.scan(rest, return: :index)
      |> Enum.map(fn [{start, _len}, keyword, token] ->
        {start,
         {rest |> SQLMask.cut(keyword) |> String.upcase(), token(SQLMask.cut(rest, token))}}
      end)
      |> Enum.reject(&match?({_start, {_keyword, :not_a_clause}}, &1))

    {found, Enum.map(found, &elem(&1, 1))}
  end

  @spec error(:ok | {:error, SQLError.t()}) :: SQLError.t() | nil
  defp error(:ok), do: nil
  defp error({:error, error}), do: error

  @spec token(binary()) :: token()
  defp token(token) do
    upper = String.upcase(token)

    cond do
      Regex.match?(~r/^[0-9]+$/u, token) ->
        integer_token(String.to_integer(token))

      Regex.match?(~r/^-[0-9]+$/u, token) ->
        {:negative, token}

      Regex.match?(~r/^(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)(?:[eE][+-]?[0-9]+)?$/u, token) ->
        {:type, "Float64"}

      upper == "NULL" ->
        :null

      upper in @limit_keywords or Regex.match?(~r/^[=<>!,)~]/u, token) ->
        :not_a_clause

      match = Regex.run(~r/^\$(\w+)$/u, token) ->
        {:param, List.last(match)}

      Regex.match?(~r/^[\p{L}_]\w*$/u, token) ->
        {:name, token}

      true ->
        :other
    end
  end

  # A whole number is a count; past `Int64` the engine types it `UInt64`, and past that `Float64`.
  @spec integer_token(non_neg_integer()) :: token()
  defp integer_token(number) when number > @uint64_max, do: {:type, "Float64"}
  defp integer_token(number) when number > @int64_max, do: {:wide, number}
  defp integer_token(number), do: {:count, number}

  # Whatever follows the first clause must be clauses and nothing else.
  @spec trailing_garbage?([{non_neg_integer(), term()}], binary()) :: boolean()
  defp trailing_garbage?([], _rest), do: false

  defp trailing_garbage?([{start, _clause} | _more], rest) do
    tail = binary_part(rest, start, byte_size(rest) - start)
    not Regex.match?(~r/(?i)^(?:(?:LIMIT|OFFSET)\s+\S+\s*)+$/u, tail)
  end

  @spec refusal([{binary(), token()}], boolean(), binary()) :: :ok | {:error, SQLError.t()}
  defp refusal(clauses, garbage?, sql) do
    cond do
      Enum.any?(clauses, &match?({"LIMIT", :other}, &1)) ->
        {:error,
         SQLError.refusal("unsupported LIMIT (a non-negative integer is required): #{sql}")}

      Enum.any?(clauses, &match?({"OFFSET", :other}, &1)) ->
        {:error, offset_refusal(sql)}

      garbage? or too_many?(clauses) ->
        {:error, offset_refusal(sql)}

      true ->
        :ok
    end
  end

  @spec offset_refusal(binary()) :: SQLError.t()
  defp offset_refusal(sql),
    do:
      SQLError.refusal("unsupported LIMIT / OFFSET (non-negative integers are required): #{sql}")

  # One LIMIT and one OFFSET at most.
  @spec too_many?([{binary(), token()}]) :: boolean()
  defp too_many?(clauses),
    do:
      Enum.count(clauses, &(elem(&1, 0) == "LIMIT")) > 1 or
        Enum.count(clauses, &(elem(&1, 0) == "OFFSET")) > 1

  @spec planning([{binary(), token()}]) :: :ok | {:error, SQLError.t()}
  defp planning(clauses) do
    case Enum.find(clauses, &match?({_keyword, {:name, _name}}, &1)) do
      {_keyword, {:name, name}} ->
        {:error, %{status: 500, body: "Schema error: No field named #{name}."}}

      nil ->
        case Enum.find(clauses, &match?({_keyword, {:type, _type}}, &1)) do
          {keyword, {:type, type}} ->
            {:error,
             SQLError.coercion("Expected #{keyword} to be an integer or null, but got #{type}")}

          nil ->
            :ok
        end
    end
  end

  @spec optimizer([{binary(), token()}]) :: :ok | {:error, SQLError.t()}
  defp optimizer(clauses) do
    limit = Enum.find(clauses, &match?({"LIMIT", _clause}, &1))
    offset = Enum.find(clauses, &match?({"OFFSET", _clause}, &1))

    case {limit, offset} do
      {{"LIMIT", {:negative, n}}, _offset} ->
        {:error, optimizer_error("eliminate_limit", "LIMIT must be >= 0, '#{n}' was provided")}

      {{"LIMIT", {:wide, n}}, _offset} ->
        {:error, uncastable(n)}

      {_limit, {"OFFSET", {:wide, n}}} ->
        {:error, uncastable(n)}

      {_limit, {"OFFSET", {:negative, n}}} ->
        rule =
          if match?({"LIMIT", {:count, _n}}, limit),
            do: "push_down_limit",
            else: "eliminate_limit"

        {:error, optimizer_error(rule, "OFFSET must be >=0, '#{n}' was provided")}

      _valid ->
        :ok
    end
  end

  # The optimizer folds the number as an `Int64` and cannot.
  @spec uncastable(non_neg_integer()) :: SQLError.t()
  defp uncastable(number),
    do: SQLError.simplify("Arrow error: Cast error: Can't cast value #{number} to type Int64")

  @spec optimizer_error(binary(), binary()) :: SQLError.t()
  defp optimizer_error(rule, message) do
    %{
      status: 400,
      body: "Optimizer rule '#{rule}' failed\ncaused by\nError during planning: #{message}"
    }
  end

  @doc "The LIMIT of the text after the table: a count, a `$name` or `nil`."
  @spec limit(binary()) :: clause()
  def limit(rest), do: count(~r/(?i)(?<![\w.])LIMIT\s+(?:([0-9]+)|\$(\w+))/su, rest)

  @doc "The OFFSET of the text after the table: a count, a `$name` or `nil`."
  @spec offset(binary()) :: clause()
  def offset(rest), do: count(~r/(?i)(?<![\w.])OFFSET\s+(?:([0-9]+)|\$(\w+))/su, rest)

  @spec count(Regex.t(), binary()) :: clause()
  defp count(pattern, rest) do
    case Regex.run(pattern, SQLMask.mask(rest)) do
      [_full_match, n_str] -> String.to_integer(n_str)
      [_full_match, "", name] -> {:param, name}
      _no_match -> nil
    end
  end

  @doc """
  LIMIT and OFFSET with their `$name`s bound, checked as literals are: the
  planner's type error, and the optimizer's negative-number error, which is
  returned for the executor to raise in its place (the last element, `nil`
  when there is none).
  """
  @spec bind(clause(), clause(), %{binary() => term()}) ::
          {:ok, non_neg_integer() | nil, non_neg_integer() | nil, SQLError.t() | nil}
          | {:error, SQLError.t()}
  def bind(limit, offset, params) do
    clauses =
      for {keyword, value} <- [{"LIMIT", limit}, {"OFFSET", offset}], value != nil do
        {keyword, value_token(value, params)}
      end

    with :ok <- planning(clauses) do
      {:ok, bound_count(clauses, "LIMIT"), bound_count(clauses, "OFFSET"),
       error(optimizer(clauses))}
    end
  end

  @spec value_token(non_neg_integer() | {:param, binary()}, %{binary() => term()}) :: token()
  defp value_token(count, _params) when is_integer(count), do: {:count, count}

  defp value_token({:param, name}, params) do
    case Map.fetch!(params, name) do
      value when is_integer(value) and value >= 0 -> integer_token(value)
      value when is_integer(value) -> {:negative, Integer.to_string(value)}
      value when is_float(value) -> {:type, "Float64"}
      value when is_binary(value) -> {:type, "Utf8"}
      value when is_boolean(value) -> {:type, "Boolean"}
      nil -> :null
    end
  end

  @spec bound_count([{binary(), token()}], binary()) :: non_neg_integer() | nil
  defp bound_count(clauses, keyword) do
    case List.keyfind(clauses, keyword, 0) do
      {^keyword, {:count, count}} -> count
      _no_count -> nil
    end
  end
end
