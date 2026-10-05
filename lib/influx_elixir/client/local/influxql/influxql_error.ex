defmodule InfluxElixir.Client.Local.InfluxQLError do
  @moduledoc false
  # The 400 bodies of the engine's InfluxQL parser, by kind of error and the
  # position it names in the statement as sent, and the planning errors it
  # raises while it rewrites the statement.

  @engine_error_prefix "error in InfluxQL statement: parsing error: "

  # What a parse error says, by kind; the position follows as `at pos N`.
  @messages %{
    operand: "invalid conditional expression",
    regex: "invalid conditional, expected regular expression",
    overflow: "unable to parse integer due to overflow",
    duration_overflow: "overflow",
    signed_overflow: "constant overflows signed integer",
    field: "invalid SELECT statement, expected field",
    from: "invalid FROM clause, expected identifier, regular expression or subquery",
    alias: "invalid field alias, expected identifier",
    group: "invalid GROUP BY clause, expected wildcard, TIME, identifier or regular expression",
    order: "invalid ORDER BY, expected ASC, DESC or TIME",
    order_time: "invalid ORDER BY, expected TIME column",
    limit: "invalid LIMIT clause, expected unsigned integer",
    offset: "invalid OFFSET clause, expected unsigned integer",
    slimit: "invalid SLIMIT clause, expected unsigned integer",
    soffset: "invalid SOFFSET clause, expected unsigned integer",
    group_by: "invalid GROUP BY clause, expected BY",
    distinct: "invalid DISTINCT expression, expected identifier",
    unsigned: "unable to parse unsigned integer",
    time_call: "invalid TIME call, expected 1 or 2 arguments",
    time_interval: "invalid TIME call, expected a duration for the interval",
    time_close: "invalid TIME call, expected ')'",
    wildcard_type: "invalid wildcard type specifier, expected TAG or FIELD",
    data_type:
      "invalid data type for tag or field reference, " <>
        "expected float, integer, unsigned, string, boolean, field, tag",
    fill: "invalid FILL option, expected NULL, NONE, PREVIOUS, LINEAR, or a number",
    call:
      "invalid expression, the only valid function calls are 'now' with no arguments, " <>
        "date_part(<literal>, time), or scalar math functions",
    comment: "invalid inline comment, missing closing */",
    unterminated_string: "unterminated string literal",
    unterminated_regex: "unterminated regex literal",
    unary:
      "unexpected unary expression: expected literal integer, float, duration, field, " <>
        "function or parenthesis"
  }

  @doc """
  The body of the parse error of `kind` at `pos` in `whole`, the statement as
  sent. `:nom` is a statement the parser stops reading at `pos` (the rest is
  quoted), `:failure` one it fails to read from `pos` on (always reported at
  position 0).
  """
  @spec syntax_error_body(atom(), non_neg_integer(), binary()) :: binary()
  def syntax_error_body(:nom, pos, whole) do
    @engine_error_prefix <>
      "invalid InfluxQL statement at pos #{pos}. " <>
      "Parsing Error: Nom(#{inspect(leftover(whole, pos))}, Tag)"
  end

  def syntax_error_body(:failure, pos, whole) do
    @engine_error_prefix <>
      "invalid InfluxQL statement at pos 0. " <>
      "Parsing Failure: Nom(#{inspect(leftover(whole, pos))}, Char)"
  end

  def syntax_error_body(kind, pos, _whole),
    do: @engine_error_prefix <> "#{Map.fetch!(@messages, kind)} at pos #{pos}"

  @spec leftover(binary(), non_neg_integer()) :: binary()
  defp leftover(whole, pos), do: binary_part(whole, pos, byte_size(whole) - pos)

  @split_prefix "rewriting statement\ncaused by\nsplit condition\ncaused by\n"

  @doc "The error the engine raises while it rewrites the statement."
  @spec rewrite_error(binary()) :: binary()
  def rewrite_error(message), do: "rewriting statement\ncaused by\n" <> message

  @doc """
  The planning error the engine raises while it splits the `WHERE` from its
  `time` bounds: the engine's wording of `message`.
  """
  @spec split_error(binary()) :: binary()
  def split_error(message), do: @split_prefix <> message

  @doc """
  The message of a `split_error/1` without its frame: `SHOW TAG VALUES`
  answers with the message alone.
  """
  @spec unframe_split(binary()) :: binary()
  def unframe_split(body), do: String.replace_prefix(body, @split_prefix, "")

  @doc """
  The planning error the engine raises while it expands the projection of the
  select list (`message` after its `Error during planning: `).
  """
  @spec expand_error(binary()) :: binary()
  def expand_error(message) do
    "rewriting statement\ncaused by\nexpand projection\ncaused by\n" <>
      "Error during planning: " <> message
  end

  @doc """
  The planning error the engine raises while it gathers what the select list
  asks for: `message` after the engine's `Error during planning: `.
  """
  @spec select_error(binary()) :: binary()
  def select_error(message) do
    "rewriting statement\ncaused by\ngather information about select statement\n" <>
      "caused by\nError during planning: " <> message
  end

  @doc """
  The planning error the engine raises while it finds the offset of a `GROUP BY
  time()` for a quoted offset that is no timestamp: `quoted` is the literal as
  written, quotes included.
  """
  @spec offset_error(binary()) :: binary()
  def offset_error(quoted) do
    "rewriting statement\ncaused by\nfind interval offset\ncaused by\n" <>
      "Error during planning: invalid expression #{inspect(quoted)}: " <>
      "#{quoted} is not a valid timestamp"
  end

  @doc "Moves the positions of a parse error body on by `by` bytes."
  @spec shift_position(binary(), non_neg_integer()) :: binary()
  def shift_position(body, by) do
    Regex.replace(~r/at pos (\d+)/, body, fn _match, pos ->
      "at pos #{String.to_integer(pos) + by}"
    end)
  end

  @doc """
  The body for a `WHERE` the tokens of which stop at `pos`, by the `kind`
  `InfluxElixir.Client.Local.InfluxQLTokens` gives: `where_at` is where the
  `WHERE` starts.
  """
  @spec where_error_body(atom(), non_neg_integer(), non_neg_integer(), binary()) :: binary()
  def where_error_body(:where_unparsed, _pos, where_at, whole),
    do: syntax_error_body(:nom, where_at, whole)

  def where_error_body(:reserved_operand, pos, _where_at, whole),
    do: syntax_error_body(:operand, before_operand(whole, pos), whole)

  def where_error_body(:reserved_operator, pos, _where_at, whole),
    do: syntax_error_body(:nom, before_operand(whole, pos) - 1, whole)

  def where_error_body(:reserved_failure, pos, _where_at, whole),
    do: syntax_error_body(:failure, pos, whole)

  def where_error_body(kind, pos, _where_at, whole), do: syntax_error_body(kind, pos, whole)

  @doc """
  The end of the operator before the operand that starts at `pos`:
  whitespace, opening parentheses and unary signs between them are skipped.
  """
  @spec before_operand(binary(), non_neg_integer()) :: non_neg_integer()
  def before_operand(whole, pos) do
    skipped = whole |> binary_part(0, pos) |> String.reverse()
    [spaces] = Regex.run(~r/^[\s(+\-]*/, skipped)
    pos - byte_size(spaces)
  end
end
