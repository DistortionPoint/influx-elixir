defmodule InfluxElixir.Client.Local.InfluxQLSql do
  @moduledoc false
  # Writes the tokens of an InfluxQL comparison as the SQL the caller's engine
  # reads: a missing tag, a double-quoted identifier, a regular expression, a
  # duration next to `now()`.

  alias InfluxElixir.Client.Local.InfluxQLRegex

  # A duration next to `now()` is an interval in whole seconds, the unit
  # the SQL engine's INTERVAL takes; a finer one is refused by name.
  @doc false
  @spec duration_sql(non_neg_integer(), binary()) :: binary()
  def duration_sql(ns, _text) when rem(ns, 1_000_000_000) == 0,
    do: "INTERVAL '#{div(ns, 1_000_000_000)} seconds'"

  def duration_sql(_ns, text),
    do: throw({:refused, "unsupported InfluxQL (sub-second duration #{text})"})

  @doc """
  The tokens of a comparison as SQL. A regular expression is matched against
  a tag or a string field (`strings`) and is false for any other column.
  """
  @spec rewrite(list(), MapSet.t(binary()), [binary()]) :: [binary()]
  # No string fields: the tags without the tags.
  def rewrite(tokens, tags, acc), do: rewrite(tokens, tags, MapSet.difference(tags, tags), acc)

  @doc false
  @spec rewrite(list(), MapSet.t(binary()), MapSet.t(binary()), [binary()]) :: [binary()]
  def rewrite([], _tags, _strings, acc), do: Enum.reverse(acc)

  # A regular expression matched against a string constant keeps no point, whether it matches
  # or not (verified: `'us' =~ /us/` and `'us' !~ /zzz/` are both empty, and an `OR` beside
  # either reads as if it were false).
  def rewrite([{:str, _content}, {:op, op}, {:regex, _pattern} | rest], tags, strings, acc)
      when op in ["=~", "!~"],
      do: rewrite(rest, tags, strings, ["(1 = 0)" | acc])

  def rewrite([{:ident, name}, {:op, op}, {:regex, pattern} | rest], tags, strings, acc) do
    regex = InfluxQLRegex.pattern(pattern)

    sql =
      cond do
        MapSet.member?(tags, name) -> regex_sql(name, op, regex)
        MapSet.member?(strings, name) -> string_regex_sql(name, op, regex)
        true -> always_false(name)
      end

    rewrite(rest, tags, strings, [sql | acc])
  end

  def rewrite([{:ident, name}, {:op, op}, value | rest], tags, strings, acc)
      when op in ["<", "<=", ">", ">="] do
    if MapSet.member?(tags, name),
      do: rewrite(rest, tags, strings, [always_false(name) | acc]),
      else: rewrite(rest, tags, strings, [token_sql(value), op, ident_sql(name) | acc])
  end

  # Two tags compared are false for every row, whichever the operator
  # (verified: `k = x` on points where they hold the same value, `k != x`
  # where they differ, `k = k`).
  def rewrite([{:ident, name}, {:op, op}, {:ident, other} | rest], tags, strings, acc)
      when op in ["=", "!=", "<>"] do
    if MapSet.member?(tags, name) and MapSet.member?(tags, other),
      do: rewrite(rest, tags, strings, [always_false(name) | acc]),
      else: rewrite(rest, tags, strings, [token_sql({:ident, other}), op, ident_sql(name) | acc])
  end

  def rewrite([token | rest], tags, strings, acc),
    do: rewrite(rest, tags, strings, [token_sql(token) | acc])

  # The SQL path refuses a bare `.*` beside `!~` (its simplifier rewrites that, which is not
  # the expression's meaning). InfluxQL has no `NOT`, and the engine answers its `=~ /.*/` and
  # `!~ /.*/` on a tag as the expression reads (verified: a missing tag is the empty string,
  # which `.*` matches), so the pattern is written as the group the SQL path does not rewrite.
  @spec regex_sql(binary(), binary(), binary()) :: binary()
  defp regex_sql(name, op, regex) do
    regex = if regex == ".*", do: "(?:.*)", else: regex

    operator = if op == "=~", do: "~", else: "!~"
    "#{ident_sql(name)} #{operator} '#{String.replace(regex, "'", "''")}'"
  end

  # The engine's optimizer folds `!~ /.*/` on a string field into `= ''`
  # (verified: it keeps the points whose value is the empty string, and no
  # other pattern, tag or field does).
  @spec string_regex_sql(binary(), binary(), binary()) :: binary()
  defp string_regex_sql(name, "!~", ".*"), do: "#{ident_sql(name)} = ''"
  defp string_regex_sql(name, op, regex), do: regex_sql(name, op, regex)

  # InfluxQL reads `+5` as 5;
  # the SQL the double hands on does not read a
  # unary plus. A `+` is unary at the start, after a comparison operator,
  # after an opening parenthesis and after another sign or operator.
  @spec drop_unary_plus(list(), list()) :: list()
  @doc false
  def drop_unary_plus([], acc), do: Enum.reverse(acc)
  def drop_unary_plus([{:raw, "+"} | rest], []), do: drop_unary_plus(rest, [])

  def drop_unary_plus([{:raw, "+"} | rest], [{:op, _op} | _more] = acc),
    do: drop_unary_plus(rest, acc)

  def drop_unary_plus([{:raw, "+"} | rest], [{:raw, prev} | _more] = acc)
      when prev in ["(", "+", "-", "*", "/"],
      do: drop_unary_plus(rest, acc)

  def drop_unary_plus([token | rest], acc), do: drop_unary_plus(rest, [token | acc])

  @spec token_sql(tuple()) :: binary()
  defp token_sql({:ident, name}), do: ident_sql(name)
  defp token_sql({:str, content}), do: "'" <> content <> "'"
  defp token_sql({:regex, pattern}), do: "'" <> String.replace(pattern, "'", "''") <> "'"
  defp token_sql({:op, op}), do: op
  defp token_sql({:raw, text}), do: text
  defp token_sql({:number, "." <> _fraction = text}), do: "0" <> text
  defp token_sql({:number, text}), do: text
  defp token_sql({:duration, ns, text}), do: duration_sql(ns, text)

  # Words the SQL the double hands on reads as keywords, though InfluxQL
  # takes them as names.
  @sql_words ~w(not is like ilike between case when then else exists)

  @spec ident_sql(binary()) :: binary()
  @doc false
  def ident_sql(name) do
    if Regex.match?(~r/^[A-Za-z_]\w*$/, name) and String.downcase(name) not in @sql_words,
      do: name,
      else: ~s("#{name}")
  end

  # False for every row, in the SQL the caller's engine reads.
  @spec always_false(binary()) :: binary()
  defp always_false(name),
    do: "(#{ident_sql(name)} IS NULL AND #{ident_sql(name)} IS NOT NULL)"
end
