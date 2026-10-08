defmodule InfluxElixir.Client.Local.InfluxQLParens do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
  # The parentheses of an InfluxQL `WHERE`, as the engine's parser reads them
  # (verified). A `)` that closes nothing ends the condition: the statement is
  # left from it. A `(` that is never closed makes the parser give up on the
  # parenthesised condition, and the error depends on what stands before it, as
  # for a reserved word where an operand is wanted
  # (see `InfluxQLTokens`): at the start
  # the whole `WHERE` is left unparsed, after a comparison or a connective the
  # operand is missing, after a binary `+` or `-` the engine fails from the
  # parenthesis, after an operand the parenthesis is left over. The last
  # parenthesis left open decides.

  alias InfluxElixir.Client.Local.{InfluxQLCheck, InfluxQLError, InfluxQLLex, InfluxQLTokens}

  # `now()` has parentheses of its own, which are no grouping.
  @parens ~q/(?<![\w])now\s*\(\s*\)|[()]/i

  @doc """
  `nil` when the parentheses of the `WHERE` balance, else the engine's error with its position.
  `tokens` are those of the condition, `masked` its text with the inside of
  literals blanked, `start` where it starts in `whole` (the statement as
  sent) and `where_at` where its `WHERE` does.
  """
  @spec check(list(), binary(), non_neg_integer(), non_neg_integer(), binary()) ::
          InfluxQLCheck.positioned() | nil
  def check(tokens, masked, start, where_at, whole) do
    case scan(masked) do
      :balanced ->
        nil

      {:excess, offset} ->
        InfluxQLCheck.fail(:nom, start + offset, whole)

      {:open, offset, ordinal} ->
        kind = tokens |> before_open(ordinal) |> InfluxQLTokens.reserved_kind()
        {_key, body} = InfluxQLError.where_error(kind, start + offset, where_at, whole)

        # A `(` left open is found when the condition ends, not where it stands: whatever the
        # parser meets inside the condition comes first (verified: a call it refuses, `fill(1)`,
        # is the error before, inside or after an open parenthesis).
        InfluxQLCheck.found_at({0, {:error, {:engine, body}}}, start + byte_size(masked))
    end
  end

  @doc "Whether a `)` in `masked` closes nothing: the condition ends there."
  @spec excess_close?(binary()) :: boolean()
  def excess_close?(masked), do: excess_offset(masked) != nil

  @doc "Where the first `)` in `masked` that closes nothing stands, `nil` for none."
  @spec excess_offset(binary()) :: non_neg_integer() | nil
  def excess_offset(masked) do
    case scan(masked) do
      {:excess, offset} -> offset
      _balanced_or_open -> nil
    end
  end

  # The first `)` that closes nothing, else the last `(` left open with the
  # number of `(` before it.
  @spec scan(binary()) :: :balanced | {:excess, non_neg_integer()} | {:open, integer(), integer()}
  defp scan(masked) do
    parens =
      for [{at, 1}] <- Regex.scan(@parens, masked, return: :index),
          do: {at, :binary.at(masked, at)}

    walk(parens, [], 0, masked, nil)
  end

  # `closed` is where the last `)` ended: a `(` right after it is left over from itself.
  defp walk([], [], _count, _masked, _closed), do: :balanced

  defp walk([], [{offset, ordinal} | _outer], _count, _masked, _closed),
    do: {:open, offset, ordinal}

  defp walk([{at, ?(} | rest], open, count, masked, closed) do
    if closed != nil and
         InfluxQLLex.trim_both_blanks(binary_part(masked, closed, at - closed)) == "",
       do: {:excess, at},
       else: walk(rest, [{at, count} | open], count + 1, masked, nil)
  end

  defp walk([{at, ?)} | _rest], [], _count, _masked, _closed), do: {:excess, at}

  # A pair with nothing in it is as unreadable as a `(` left open, unless it is the call of a
  # function with no arguments (`abs()`: the planner has its say).
  defp walk([{at, ?)} | rest], [{offset, ordinal} | outer], count, masked, _closed) do
    inside = binary_part(masked, offset + 1, at - offset - 1)

    if InfluxQLLex.trim_both_blanks(inside) == "" and not call?(masked, offset),
      do: {:open, offset, ordinal},
      else: walk(rest, outer, count, masked, at + 1)
  end

  defp call?(masked, offset),
    do: masked |> binary_part(0, offset) |> String.match?(~q/[A-Za-z_]\w*$/)

  # The tokens before the `(` that has `ordinal` before it, latest first.
  @spec before_open(list(), non_neg_integer()) :: list()
  defp before_open(tokens, ordinal), do: before_open(tokens, ordinal, [])

  defp before_open([{:raw, "("} | _rest], 0, acc), do: acc

  defp before_open([{:raw, "("} = token | rest], n, acc),
    do: before_open(rest, n - 1, [token | acc])

  defp before_open([token | rest], n, acc), do: before_open(rest, n, [token | acc])
end
