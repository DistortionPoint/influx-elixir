defmodule InfluxElixir.Client.Local.InfluxQLParens do
  @moduledoc false
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

  alias InfluxElixir.Client.Local.{InfluxQLError, InfluxQLTokens}

  # `now()` has parentheses of its own, which are no grouping.
  @parens ~r/(?<![\w])now\s*\(\s*\)|[()]/i

  @doc """
  `:ok` when the parentheses of the `WHERE` balance, else the engine's error.
  `tokens` are those of the condition, `masked` its text with the inside of
  literals blanked, `start` where it starts in `whole` (the statement as
  sent) and `where_at` where its `WHERE` does.
  """
  @spec check(list(), binary(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, {:engine, binary()}}
  def check(tokens, masked, start, where_at, whole) do
    case scan(masked) do
      :balanced ->
        :ok

      {:excess, offset} ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:nom, start + offset, whole)}}

      {:open, offset, ordinal} ->
        kind = tokens |> before_open(ordinal) |> InfluxQLTokens.reserved_kind()
        body = InfluxQLError.where_error_body(kind, start + offset, where_at, whole)
        {:error, {:engine, body}}
    end
  end

  # The first `)` that closes nothing, else the last `(` left open with the
  # number of `(` before it.
  @spec scan(binary()) :: :balanced | {:excess, non_neg_integer()} | {:open, integer(), integer()}
  defp scan(masked) do
    parens =
      for [{at, 1}] <- Regex.scan(@parens, masked, return: :index),
          do: {at, :binary.at(masked, at)}

    walk(parens, [], 0, masked)
  end

  defp walk([], [], _count, _masked), do: :balanced
  defp walk([], [{offset, ordinal} | _outer], _count, _masked), do: {:open, offset, ordinal}

  defp walk([{at, ?(} | rest], open, count, masked),
    do: walk(rest, [{at, count} | open], count + 1, masked)

  defp walk([{at, ?)} | _rest], [], _count, _masked), do: {:excess, at}

  # A pair with nothing in it is as unreadable as a `(` left open.
  defp walk([{at, ?)} | rest], [{offset, ordinal} | outer], count, masked) do
    inside = binary_part(masked, offset + 1, at - offset - 1)

    if String.trim(inside) == "",
      do: {:open, offset, ordinal},
      else: walk(rest, outer, count, masked)
  end

  # The tokens before the `(` that has `ordinal` before it, latest first.
  @spec before_open(list(), non_neg_integer()) :: list()
  defp before_open(tokens, ordinal), do: before_open(tokens, ordinal, [])

  defp before_open([{:raw, "("} | _rest], 0, acc), do: acc

  defp before_open([{:raw, "("} = token | rest], n, acc),
    do: before_open(rest, n - 1, [token | acc])

  defp before_open([token | rest], n, acc), do: before_open(rest, n, [token | acc])
end
