defmodule InfluxElixir.Client.Local.InfluxQLShowClauses do
  @moduledoc false
  # The clauses of a `SHOW` statement, one function each, as the engine's
  # parser reads them (verified): `ON`, `FROM`, `WITH MEASUREMENT`, `WHERE`,
  # `WITH KEY`, `LIMIT` and `OFFSET`. `clause/4` takes the name of a clause, the
  # scanned statement, where to look for it and the spec read so far:
  # `{:ok, spec, end_of_clause}`, `:none` when the clause is not there, or the
  # engine's parse error. The conditions are `InfluxQLShowCondition`.

  alias InfluxElixir.Client.Local.{InfluxQLError, InfluxQLShowCondition}
  alias InfluxElixir.Client.Local.InfluxQLShowText, as: Text

  @uint64_max 18_446_744_073_709_551_615

  @doc "Reads the clause `name` of a `SHOW` statement at `pos`."
  @spec clause(atom(), Text.ctx(), non_neg_integer(), map()) :: Text.step()
  def clause(:on, ctx, pos, spec), do: on(ctx, pos, spec)
  def clause(:on_wild, ctx, pos, spec), do: on_wild(ctx, pos, spec)
  def clause(:from, ctx, pos, spec), do: from(ctx, pos, spec)
  def clause(:with_measurement, ctx, pos, spec), do: with_measurement(ctx, pos, spec)
  def clause(:where, ctx, pos, spec), do: InfluxQLShowCondition.where(ctx, pos, spec)
  def clause(:limit, ctx, pos, spec), do: count(ctx, pos, "limit", :limit, spec)
  def clause(:offset, ctx, pos, spec), do: count(ctx, pos, "offset", :offset, spec)
  def clause(:with_key, ctx, pos, spec), do: with_key(ctx, pos, spec)

  # `ON db`: past `ON` the engine wants a blank and a name; without them it is
  # its error at the end of `ON`.
  defp on(ctx, pos, spec) do
    with {:ok, at} <- Text.keyword(ctx, pos, "on"),
         to = at + 2,
         true <- Text.at_byte(ctx, to) not in ["\"", "."] || :none do
      case Text.ws?(ctx, to) and Text.name_at(ctx, Text.skip_ws(ctx, to)) do
        {:ok, name, after_name} -> {:ok, %{spec | on: name}, after_name}
        {:error, _reason} = error -> error
        _no_name -> Text.error("invalid ON clause, expected identifier", to)
      end
    end
  end

  # `SHOW MEASUREMENTS ON`: a name or a wildcard, after a blank.
  defp on_wild(ctx, pos, spec) do
    with {:ok, at} <- Text.keyword(ctx, pos, "on"),
         true <- Text.ws?(ctx, at + 2) || :none do
      first = Text.skip_ws(ctx, at + 2)

      case Text.name_at(ctx, first) do
        {:ok, name, after_name} -> qualified_database(ctx, first, name, after_name, spec)
        {:error, _reason} = error -> error
        :none -> wildcard(ctx, first, spec)
      end
    end
  end

  # `db.rp` names the database `db/rp`, except for the policy `autogen`, which
  # is `db` itself (verified); `db.` and `db.*` fail where the name starts.
  @spec qualified_database(Text.ctx(), non_neg_integer(), binary(), non_neg_integer(), map()) ::
          Text.step()
  defp qualified_database(ctx, first, name, after_name, spec) do
    if Text.at_byte(ctx, after_name) == "." do
      case Text.name_at(ctx, after_name + 1) do
        {:ok, "autogen", to} -> {:ok, %{spec | on: name}, to}
        {:ok, policy, to} -> {:ok, %{spec | on: name <> "/" <> policy}, to}
        _no_policy -> Text.error("invalid ON clause, expected wildcard or identifier", first)
      end
    else
      {:ok, %{spec | on: name}, after_name}
    end
  end

  # `ON *` reads, and the engine refuses it when it plans the statement.
  defp wildcard(ctx, at, spec) do
    if Text.at_byte(ctx, at) == "*" do
      deferred = Text.defer(spec, {:statement, "can only perform queries on a single database"})
      {:ok, deferred, at + 1}
    else
      Text.error("invalid ON clause, expected wildcard or identifier", at)
    end
  end

  defp from(ctx, pos, spec) do
    with {:ok, at} <- Text.keyword(ctx, pos, "from"),
         true <- Text.ws?(ctx, at + 4) || :none do
      first = Text.skip_ws(ctx, at + 4)

      case Text.sources(ctx, first) do
        {:ok, items, to} ->
          {:ok, from_items(spec, items), to}

        :none ->
          Text.error("invalid FROM clause, expected identifier or regular expression", first)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp from_items(spec, items) do
    spec =
      Enum.reduce(items, spec, fn
        {:unavailable, message}, acc -> Text.defer(acc, {:not_implemented, message})
        _source, acc -> acc
      end)

    %{
      spec
      | from: Enum.filter(items, &match?({kind, _name_or_regex} when kind in [:name, :regex], &1))
    }
  end

  defp with_measurement(ctx, pos, spec) do
    with {:ok, at} <- Text.keyword(ctx, pos, "with"),
         true <- Text.ws?(ctx, at + 4) || :none do
      word = Text.skip_ws(ctx, at + 4)

      case Text.keyword_here(ctx, word, "measurement") do
        {:ok, to} -> InfluxQLShowCondition.measurement(ctx, to, spec)
        :no -> Text.error("invalid WITH clause, expected MEASUREMENT", word)
      end
    end
  end

  # `WITH KEY` is required; each way it fails is the engine's error at the
  # place it names (the end of the word before it, or past the blank).
  defp with_key(ctx, pos, spec) do
    with true <- Text.ws?(ctx, pos),
         at = Text.skip_ws(ctx, pos),
         {:ok, to} <- Text.keyword_here(ctx, at, "with"),
         true <- Text.ws?(ctx, to) do
      word = Text.skip_ws(ctx, to)

      case Text.keyword_here(ctx, word, "key") do
        {:ok, after_key} -> InfluxQLShowCondition.key(ctx, after_key, spec)
        :no -> Text.error("invalid WITH KEY clause, expected KEY", word)
      end
    else
      _absent ->
        Text.error("invalid SHOW TAG VALUES statement, expected WITH KEY clause", pos)
    end
  end

  # ---- LIMIT and OFFSET -----------------------------------------------------------

  defp count(ctx, pos, name, field, spec) do
    with {:ok, at} <- Text.keyword(ctx, pos, name),
         true <- Text.ws?(ctx, at + byte_size(name)) || :none do
      from = Text.skip_ws(ctx, at + byte_size(name))

      case Regex.run(~r/^\d+/, binary_part(ctx.masked, from, ctx.size - from)) do
        [digits] -> number(digits, from, field, ctx, spec)
        nil -> {:error, {:engine, InfluxQLError.syntax_error_body(field, from, ctx.raw)}}
      end
    end
  end

  defp number(digits, from, field, ctx, spec) do
    value = String.to_integer(digits)
    to = from + byte_size(digits)

    cond do
      value > @uint64_max ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:unsigned, to, ctx.raw)}}

      # The largest LIMIT with an OFFSET after it keeps nothing (verified).
      field == :offset and value > 0 and spec.limit == @uint64_max and
          spec.kind != :measurements ->
        {:error, "unsupported InfluxQL (the largest LIMIT with an OFFSET)"}

      true ->
        {:ok, Map.put(spec, field, value), to}
    end
  end
end
