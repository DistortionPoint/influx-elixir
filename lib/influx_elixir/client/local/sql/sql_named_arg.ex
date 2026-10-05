defmodule InfluxElixir.Client.Local.SQLNamedArg do
  @moduledoc false
  # The engine's error for a call with a named argument (`abs(x => 1)`), for
  # `InfluxElixir.Client.Local.SQLSyntax` (verified against InfluxDB 3 Core, every function the
  # double has and the aggregates, in a select list and with a `FROM`).
  #
  # The parser reads `name => value` in any call. The planner then looks the function up, before
  # it converts any argument, so the error names the function whatever the arguments hold:
  #
  #     Error during planning: Function 'abs' does not support named arguments
  #     Error during planning: Aggregate function 'max' does not support named arguments
  #
  # The name printed is the function's own, not the spelling written (`length` is
  # `character_length`, `pow` is `power`, `stddev_samp` is `stddev`). Two kinds of call have
  # another answer, which the double refuses by name (`unknown_before/1`): `substr` and
  # `substring`, which take names, and a function the engine does not have, whose `Invalid
  # function` suggestion (`Did you mean 'ln'?`) is another name each time it is asked.

  alias InfluxElixir.Client.Local.SQLError

  # The functions that refuse names, as written => as the engine prints them.
  @scalar %{
    "length" => "character_length",
    "pow" => "power"
  }
  @scalar_same ~w(abs round trunc floor ceil coalesce nullif lower upper starts_with left right
    sqrt ln log power greatest least now date_bin date_trunc to_timestamp concat ascii)
  @aggregate %{"stddev_samp" => "stddev", "var_samp" => "var"}
  @aggregate_same ~w(count sum avg min max median stddev stddev_pop var var_pop approx_distinct
    first_value last_value array_agg bool_and bool_or)

  @doc """
  The engine's error for a call of `name` (as written, an unquoted word) with a named argument,
  or the refusal of the calls it does not give an answer for.
  """
  @spec error(binary()) :: SQLError.t()
  def error(name) do
    lower = String.downcase(name)

    cond do
      lower in @scalar_same ->
        SQLError.planning("Function '#{lower}' does not support named arguments")

      is_map_key(@scalar, lower) ->
        SQLError.planning("Function '#{@scalar[lower]}' does not support named arguments")

      lower in @aggregate_same ->
        SQLError.planning("Aggregate function '#{lower}' does not support named arguments")

      is_map_key(@aggregate, lower) ->
        SQLError.planning(
          "Aggregate function '#{@aggregate[lower]}' does not support named arguments"
        )

      true ->
        unknown_before(name)
    end
  end

  @doc "Whether the double knows a function by this name (any case)."
  @spec known?(binary()) :: boolean()
  def known?(name) do
    lower = String.downcase(name)

    lower in @scalar_same or lower in @aggregate_same or is_map_key(@scalar, lower) or
      is_map_key(@aggregate, lower)
  end

  @doc "The refusal for a call to a function the double does not know, before a named argument."
  @spec unknown_before(binary()) :: SQLError.t()
  def unknown_before(name) do
    SQLError.refusal(
      "a call to #{name}, a function the double does not know, beside a call with a named " <>
        "argument: which of the two errors the engine gives first is not modelled"
    )
  end

  @doc "The refusal for a named argument in a text that names tables or columns."
  @spec with_names() :: SQLError.t()
  def with_names do
    SQLError.refusal(
      "a named argument in a text that names columns or tables: which error the engine gives " <>
        "first depends on the clause"
    )
  end
end
