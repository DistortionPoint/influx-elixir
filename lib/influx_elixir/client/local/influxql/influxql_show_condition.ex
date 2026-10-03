defmodule InfluxElixir.Client.Local.InfluxQLShowCondition do
  @moduledoc false
  # The conditions of a `SHOW` statement, as the engine's parser reads them
  # (verified): the `WHERE` of `MEASUREMENTS`, `TAG KEYS` and `TAG VALUES`
  # (read by the grammar of a `SELECT`'s `WHERE`, `InfluxQLCheck` and
  # `InfluxQLTokens`), the `WITH MEASUREMENT = name | =~ /re/` of `SHOW
  # MEASUREMENTS` and the `WITH KEY = | != | =~ | !~ | IN (...)` of `SHOW TAG
  # VALUES`. Each takes the spec read so far and returns it with the condition
  # added, with where the clause ends, or the engine's parse error.

  alias InfluxElixir.Client.Local.{InfluxQLCheck, InfluxQLTokens}
  alias InfluxElixir.Client.Local.InfluxQLShowText, as: Text

  @cond_end ~r/\b(?:LIMIT|OFFSET|SLIMIT|SOFFSET|GROUP|ORDER|FILL)\b|;/i

  # ---- WHERE ------------------------------------------------------------------

  @doc """
  The `WHERE` clause at `pos`: `:none` when it is not there or holds nothing;
  a condition the engine stops reading half way is refused by name.
  """
  @spec where(Text.ctx(), non_neg_integer(), map()) :: Text.step()
  def where(ctx, pos, spec) do
    with {:ok, at} <- Text.keyword(ctx, pos, "where"),
         true <- Text.ws?(ctx, at + 5) || :none do
      from = Text.skip_ws(ctx, at + 5)
      to = condition_end(ctx, from)
      text = ctx.clean |> binary_part(from, to - from) |> String.trim_trailing()

      if text == "", do: :none, else: condition(ctx, text, from + byte_size(text), spec)
    end
  end

  # The condition ends at the clause word (or `;`) that follows it.
  @spec condition_end(Text.ctx(), non_neg_integer()) :: non_neg_integer()
  defp condition_end(ctx, from) do
    tail = binary_part(ctx.masked, from, ctx.size - from)

    case Regex.run(@cond_end, tail, return: :index) do
      [{at, _size}] -> from + at
      nil -> ctx.size
    end
  end

  defp condition(ctx, text, to, spec) do
    case InfluxQLCheck.check_where(ctx.raw, 0, ctx.masked, text) do
      :ok -> read_condition(text, to, spec)
      {:error, _engine} = error -> error
    end
  end

  # Operands side by side are a condition the engine stops reading half way.
  defp read_condition(text, to, spec) do
    case InfluxQLTokens.tokenize(text, []) do
      {:ok, tokens} ->
        if adjacent_operands?(tokens),
          do: {:error, "unsupported InfluxQL (a WHERE the double does not read to its end)"},
          else: {:ok, %{spec | where: text}, to}

      _unread ->
        {:ok, %{spec | where: text}, to}
    end
  end

  defp adjacent_operands?(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [left, right] -> operand?(left) and operand?(right) end)
  end

  defp operand?({kind, _value}) when kind in [:ident, :str, :number], do: true
  defp operand?({:duration, _total, _text}), do: true
  defp operand?(_token), do: false

  # ---- WITH MEASUREMENT ---------------------------------------------------------

  @doc "What follows `WITH MEASUREMENT`: `= name` or `=~ /re/`."
  @spec measurement(Text.ctx(), non_neg_integer(), map()) :: Text.step()
  def measurement(ctx, to, spec) do
    op = Text.skip_ws(ctx, to)

    cond do
      Text.rest_starts?(ctx, op, "=~") -> measurement_regex(ctx, op, spec)
      Text.rest_starts?(ctx, op, "=") -> measurement_name(ctx, Text.skip_ws(ctx, op + 1), spec)
      true -> Text.error("expected = or =~", op)
    end
  end

  # After `=` the engine wants a name; a regular expression is its planning
  # error.
  defp measurement_name(ctx, at, spec) do
    if Text.at_byte(ctx, at) == "/" do
      {_source, to} = Text.regex_literal(ctx, at)
      {:ok, Text.defer(spec, {:planning, "expected string but got regex"}), to}
    else
      case Text.source_at(ctx, at) do
        {:ok, item, to} -> {:ok, put_measurement(spec, item), to}
        :none -> Text.error("expected measurement name", at)
        {:error, _reason} = error -> error
      end
    end
  end

  # After `=~` the engine wants a regular expression; a name is its planning
  # error.
  defp measurement_regex(ctx, op, spec) do
    at = Text.skip_ws(ctx, op + 2)

    if Text.at_byte(ctx, at) == "/" do
      with {:ok, item, to} <- Text.regex_at(ctx, at), do: {:ok, put_measurement(spec, item), to}
    else
      case Text.name_at(ctx, at) do
        {:ok, _name, to} ->
          {:ok, Text.defer(spec, {:planning, "expected regex but got string"}), to}

        :none ->
          Text.error("expected measurement name", op + 1)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp put_measurement(spec, {:unavailable, message}),
    do: Text.defer(spec, {:not_implemented, message})

  defp put_measurement(spec, item), do: %{spec | measurement: item}

  # ---- WITH KEY ---------------------------------------------------------------------

  @doc "What follows `WITH KEY`: `= name`, `!= name`, `=~ /re/`, `!~ /re/` or `IN (names)`."
  @spec key(Text.ctx(), non_neg_integer(), map()) :: Text.step()
  def key(ctx, after_key, spec) do
    op = Text.skip_ws(ctx, after_key)

    cond do
      Text.rest_starts?(ctx, op, "=~") -> key_regex(ctx, op + 2, true, spec)
      Text.rest_starts?(ctx, op, "!~") -> key_regex(ctx, op + 2, false, spec)
      Text.rest_starts?(ctx, op, "!=") -> key_name(ctx, op + 2, :ne, spec)
      Text.rest_starts?(ctx, op, "=") -> key_name(ctx, op + 1, :eq, spec)
      Text.rest_starts?(ctx, op, "IN") -> key_list(ctx, op + 2, spec)
      true -> Text.error("invalid WITH KEY clause, expected condition", after_key)
    end
  end

  defp key_regex(ctx, after_op, match?, spec) do
    at = Text.skip_ws(ctx, after_op)

    cond do
      Text.at_byte(ctx, at) == "/" ->
        with {:ok, {:regex, regex}, to} <- Text.regex_at(ctx, at),
             do: {:ok, %{spec | keys: {:regex, regex, match?}}, to}

      match? ->
        Text.error("invalid WITH KEY clause, expected regular expression following =~", at)

      true ->
        {:error, "unsupported InfluxQL (WITH KEY !~ with no regular expression)"}
    end
  end

  defp key_name(ctx, after_op, op, spec) do
    case Text.name_at(ctx, Text.skip_ws(ctx, after_op)) do
      {:ok, name, to} ->
        {:ok, %{spec | keys: {op, name}}, to}

      {:error, _reason} = error ->
        error

      :none when op == :eq ->
        Text.error("invalid WITH KEY clause, expected identifier following =", after_op)

      :none ->
        {:error, "unsupported InfluxQL (WITH KEY != with no name)"}
    end
  end

  defp key_list(ctx, after_in, spec) do
    open = Text.skip_ws(ctx, after_in)

    cond do
      Text.at_byte(ctx, open) != "(" ->
        Text.error("invalid WITH KEY clause, expected identifier list following IN", after_in)

      Text.ws?(ctx, open + 1) ->
        {:error, "unsupported InfluxQL (a blank after the parenthesis of WITH KEY IN)"}

      true ->
        key_names(ctx, open + 1, [], spec)
    end
  end

  defp key_names(ctx, at, acc, spec) do
    case Text.name_at(ctx, at) do
      {:ok, name, to} -> key_names_more(ctx, to, [name | acc], spec)
      {:error, _reason} = error -> error
      :none -> Text.error("invalid IN clause, expected identifier", at)
    end
  end

  # After a name: `,` and another, or `)`. A comma that no name follows is not
  # part of the list, the `)` is wanted at the end of the last name.
  defp key_names_more(ctx, to, acc, spec) do
    at = Text.skip_ws(ctx, to)

    case Text.at_byte(ctx, at) do
      ")" ->
        {:ok, %{spec | keys: {:in, Enum.reverse(acc)}}, at + 1}

      "," ->
        case Text.name_at(ctx, Text.skip_ws(ctx, at + 1)) do
          {:ok, name, after_name} -> key_names_more(ctx, after_name, [name | acc], spec)
          {:error, _reason} = error -> error
          :none -> Text.error("invalid identifier list, expected ')'", to)
        end

      _other ->
        Text.error("invalid identifier list, expected ')'", to)
    end
  end
end
