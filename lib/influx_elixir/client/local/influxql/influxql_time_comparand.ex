defmodule InfluxElixir.Client.Local.InfluxQLTimeComparand do
  @moduledoc false
  # The error of the planner when it splits the bare `time` out of a condition and the other side
  # of the comparison is no time (verified over every kind of comparand, alone and beside
  # `AND`/`OR`, in either order of the sides): the split is the first thing the planner does with
  # a condition, so this error comes before every other one of the statement, and before the
  # `invalid expr stack` that a bare operand beside the split gives.
  #
  #   * a column, a tag, the time or a name the measurement lacks: `found symbol 'n::integer',
  #     expected now() or a literal duration, float, integer and timestamp string` (the type
  #     after `::` is the column's: `integer`, `float`, `string`, `boolean`, `unsigned`, `tag`,
  #     `timestamp` for the time itself, none for a name the measurement lacks)
  #   * a boolean: `found literal 'true', expected duration, float, integer, or timestamp string`
  #   * a function: `invalid function call 'abs'`, whatever it is given
  #   * arithmetic with one of these in it: `invalid expression "n::integer + 1": ` and the error
  #     of the first of them (`-n` is written `-1 * n::integer`, a group keeps its parentheses,
  #     the error of a group in a group is the error of the one inside)
  #   * the operator `!=`/`<>`: `invalid time comparison operator: !=`, before the comparand
  #   * a chain (`time > 0 < 1`): the comparison of the first two, which the planner types as
  #     it stands: `Timestamp(ns) > Int64` for an integer literal; when the last operand is the
  #     bare time (`time > 5 < time`, `1 < time > time`) the error of the first comparison, if
  #     it has one, else a 500 `InfluxQL internal error: expected Expr`
  #
  # What is not verified (the arithmetic of strings, durations, floats and signed numbers, which
  # the planner prints in a form the double does not tell) is `:unclear`, and the caller refuses.

  alias InfluxElixir.Client.Local.{InfluxQLError, InfluxQLTokens, InfluxQLWalk}
  alias InfluxElixir.Client.Local.InfluxQLWalk.Opts

  @expected "expected now() or a literal duration, float, integer and timestamp string"
  @expected_literal "expected duration, float, integer, or timestamp string"

  @typedoc "What a comparison with the bare time comes to: nothing wrong, the error of the split (the body to raise), or what the double cannot word."
  @type answer :: :ok | {:error, binary()} | {:error, pos_integer(), binary()} | :unclear

  @doc """
  The error of the split for the comparison `tokens` (the tokens of one comparison of a
  condition), `:ok` when it is none or the comparison has no bare `time`, `{:error, body}`, or
  `:unclear`. `{:error, 500, body}` is a chain whose last operand is the bare time, which the
  engine fails with `expected Expr`.
  """
  @spec check(list(), {MapSet.t(binary()), map()}) :: answer()
  def check(tokens, ctx) do
    if InfluxQLTokens.time_comparison?(tokens),
      do: tokens |> operator_positions() |> comparison(tokens, ctx),
      else: :ok
  end

  defp operator_positions(tokens) do
    for {{:op, op}, at} <- Enum.with_index(tokens), do: {at, op}
  end

  # One comparison.
  defp comparison([{at, op}], tokens, ctx) do
    {left, [_op | right]} = Enum.split(tokens, at)
    sides(left, op, right, ctx)
  end

  # A chain: the first two operands are the comparison the planner types as it stands, unless
  # the last operand is the bare time, which it cannot place at all.
  defp comparison([{at, op}, {next, _op2} | _more], tokens, ctx) do
    {left, [_op | rest]} = Enum.split(tokens, at)
    right = Enum.take(rest, next - at - 1)

    case sides(left, op, right, ctx) do
      :ok ->
        if time_last?(tokens), do: expected_expr(), else: chain(left, op, right)

      other ->
        other
    end
  end

  defp time_last?(tokens) do
    case Enum.take(tokens, -2) do
      [{:op, _op}, last] -> InfluxQLTokens.time?(last)
      _other -> false
    end
  end

  defp expected_expr do
    {:error, 500,
     InfluxQLError.split_error("External error: InfluxQL internal error: expected Expr")}
  end

  defp sides(_left, op, _right, _ctx) when op in ["!=", "<>"],
    do:
      {:error,
       InfluxQLError.split_error("Error during planning: invalid time comparison operator: !=")}

  defp sides(_left, op, _right, _ctx) when op in ["=~", "!~"], do: :ok

  defp sides(left, _op, right, ctx) do
    comparand = if bare_time?(left), do: right, else: left

    case comparand |> InfluxQLTokens.strip_parens() |> parse(ctx) do
      :valid ->
        :ok

      :unclear ->
        :unclear

      {:invalid, message} ->
        {:error, InfluxQLError.split_error("Error during planning: " <> message)}
    end
  end

  defp bare_time?([token]), do: InfluxQLTokens.time?(token)
  defp bare_time?(_tokens), do: false

  # `time > 0 < 1`: the comparison of the time with an integer literal, whose error the planner
  # raises as the type error it is. The comparand that is no integer literal is left to the
  # caller.
  defp chain([time], op, [{:number, text}]) do
    if InfluxQLTokens.time?(time) and integer_text?(text),
      do: cannot_infer("Timestamp(ns) #{op} Int64"),
      else: :ok
  end

  defp chain(_left, _op, _right), do: :ok

  defp integer_text?(text), do: Regex.match?(~r/\A\d+\z/, text)

  defp cannot_infer(operation) do
    {:error,
     "Error during planning: Cannot infer common argument type for comparison operation " <>
       operation}
  end

  # ---------------------------------------------------------------------------
  # The comparand
  # ---------------------------------------------------------------------------

  # The comparand is walked by `InfluxQLWalk`, which gives this module the nodes of it as the
  # planner prints them (a `Part`): the text, the error it raises (`nil` when it is a valid
  # time, `:unclear` when it is an error of a form the double does not tell) and whether the
  # text is one the double knows how the planner prints.
  @behaviour InfluxElixir.Client.Local.InfluxQLWalk

  defmodule Part do
    @moduledoc false
    # A node of the comparand (see `InfluxQLTimeComparand`).
    @type t :: %__MODULE__{text: binary(), error: nil | :unclear | binary(), clear: boolean()}
    @enforce_keys [:text]
    defstruct [:text, error: nil, clear: false]
  end

  defp parse(tokens, ctx) do
    # (A plus sign before a number is not verified, as a minus sign is not: it is made part of
    # the number, which `number/3` leaves unclear.)
    case InfluxQLWalk.walk(plus_numbers(tokens, nil), __MODULE__, %Opts{ctx: ctx}) do
      {:ok, %Part{error: nil}, []} -> :valid
      {:ok, %Part{error: :unclear}, []} -> :unclear
      {:ok, %Part{error: error}, []} -> {:invalid, error}
      _unclear -> :unclear
    end
  end

  # (A sign stands at the start, or behind an operator, a parenthesis or a comma.)
  defp plus_numbers([{:raw, "+"}, {:number, text} | rest], previous)
       when previous in [nil, "+", "-", "*", "/", "(", ","],
       do: [{:number, "+" <> text} | plus_numbers(rest, text)]

  defp plus_numbers([{:raw, word} = token | rest], _previous),
    do: [token | plus_numbers(rest, word)]

  defp plus_numbers([token | rest], _previous), do: [token | plus_numbers(rest, :operand)]
  defp plus_numbers([], _previous), do: []

  # A number is clear when it is one integer; one behind a sign is not verified.
  @impl InfluxQLWalk
  def number(text, 1, _o), do: {:ok, %Part{text: text, clear: Regex.match?(~r/\A\d+\z/, text)}}
  def number(_text, -1, _o), do: {:ok, %Part{text: "?"}}

  @impl InfluxQLWalk
  def leaf([{:ident, name} = token | rest], %Opts{ctx: {tags, types}}) do
    shown =
      cond do
        InfluxQLTokens.time?(token) -> "time::timestamp"
        MapSet.member?(tags, name) -> name <> "::tag"
        Map.has_key?(types, name) -> name <> "::" <> Atom.to_string(Map.fetch!(types, name))
        true -> name
      end

    {:ok, %Part{text: shown, error: "found symbol '#{shown}', #{@expected}", clear: true}, rest}
  end

  def leaf([{:raw, "now()"} | rest], _o), do: {:ok, %Part{text: "now()", clear: true}, rest}

  def leaf([{:raw, word} | rest], _o) do
    if InfluxQLTokens.boolean_word?(word) do
      shown = String.downcase(word)
      {:ok, %Part{text: shown, error: "found literal '#{shown}', #{@expected_literal}"}, rest}
    else
      :unread
    end
  end

  # (A string or a duration is a time or another error of the planner's, its text unverified.)
  def leaf([{kind, _value} | rest], _o) when kind in [:str, :param, :regex],
    do: {:ok, %Part{text: "?"}, rest}

  def leaf([{:duration, _total, _text} | rest], _o), do: {:ok, %Part{text: "?"}, rest}
  def leaf(_tokens, _o), do: :unread

  # An expression that holds an error is that error, with the expression it is in.
  @impl InfluxQLWalk
  def combine(op, %Part{} = left, %Part{} = right, _o) do
    text = left.text <> " " <> op <> " " <> right.text
    clear = left.clear and right.clear

    case left.error || right.error do
      nil -> {:ok, %Part{text: text, clear: clear}}
      :unclear -> {:ok, %Part{text: text, error: :unclear, clear: clear}}
      error when clear -> {:ok, %Part{text: text, error: invalid(text, error), clear: clear}}
      _unwordable -> {:ok, %Part{text: text, error: :unclear, clear: clear}}
    end
  end

  defp invalid(text, error), do: "invalid expression \"#{text}\": #{error}"

  # A sign before anything but a number is the product with -1.
  @impl InfluxQLWalk
  def negate(%Part{} = operand, o), do: combine("*", %Part{text: "-1", clear: true}, operand, o)

  # A group keeps its parentheses; a group in a group is not verified.
  @impl InfluxQLWalk
  def group(%Part{} = inner, _o) do
    {:ok,
     %{
       inner
       | text: "(" <> inner.text <> ")",
         clear: inner.clear and not starts_with_group?(inner)
     }}
  end

  defp starts_with_group?(%Part{text: text}), do: String.starts_with?(text, "(")

  @impl InfluxQLWalk
  def call(name, arguments, _o) do
    shown = String.downcase(name)

    {:ok,
     %Part{
       text: shown <> "(" <> Enum.map_join(arguments, ", ", & &1.text) <> ")",
       error: "invalid function call '#{shown}'",
       clear: Enum.all?(arguments, & &1.clear)
     }}
  end
end
