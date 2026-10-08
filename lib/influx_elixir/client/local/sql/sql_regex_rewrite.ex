defmodule InfluxElixir.Client.Local.SQLRegexRewrite do
  @moduledoc false
  # The patterns the engine's simplifier rewrites before it runs them, in ways that are not the
  # regular expression's own meaning (verified against InfluxDB 3 Core 3.10.1, each shape below
  # on a table of case variants):
  #
  #   * a pattern that the engine's parser reads as literals between the start and the end of
  #     the text becomes an equality, which `~*` and `!~*` lose their case folding to:
  #     `s ~* '^abc$'` keeps only the rows equal to `abc`. The engine decides on the parsed
  #     pattern, not its text: `(?s)^abc$`, `(?:^abc)$`, `^a[b-b]c$`, `^a[\x62]c$`, `^ab{1}?c$`,
  #     `^abc(?i)$`, `^(abc)$`, `^(abc|ABC)$` and `\Aabc\z` are all that equality, and the
  #     pattern runs as written when something stands in the way: a quantifier or `.`, a class
  #     of several characters, `(?i)` before a letter, `(?m)` before `^` or `$`, a second
  #     anchor, a group of alternatives that is not a capture, a capture beside other
  #     things (`^a(b)c$`, `(?i)^abc$`, `^ab1?$`, `^a.c$`, `^[ab]c$`, `^ab\b$`, `^ab$|^a b$`)
  #   * a pattern of literals that holds a backslash (`\\`, `\x5c`, `[\\]`) becomes a `LIKE`
  #     whose escape character is that backslash: `s ~ '\\'` keeps the strings that end in `%`,
  #     `s ~ '\\ '` those that hold a space
  #   * `.*` beside a negated operator: `s !~ '.*'` is answered as a test of the value's being
  #     empty (or null), where the regular expression says none. `s ~ '.*'` is the match
  #     (a null value is false, not unknown: `SQLCondition` models that)
  #
  # The double does not model the rewrite, so a pattern that may be one of these is refused by
  # name (`unverified/2`); a pattern the rewrite leaves alone is run as written. The reader of
  # the pattern is the one `SQLRustRegex.check/1` has passed: its groups, escapes and classes
  # are the ones that reader knows.

  @backslash "a literal backslash (the engine turns a pattern of literals into a LIKE and " <>
               "leaves the backslash its escape)"
  @everything "the pattern .* beside a negated operator (the engine rewrites it, and the " <>
                "rewrite is not the expression's own meaning)"
  @anchored "an anchored literal beside a case-insensitive operator (the engine rewrites it " <>
              "to an equality that ignores the operator's case folding)"

  @flags %{ignore_case: false, multi_line: false}
  @controls %{"n" => "\n", "t" => "\t", "r" => "\r", "f" => "\f", "a" => "\a"}

  @doc """
  Why the double declines a pattern for the operator (`~`, `~*`, `!~`, `!~*`), or `nil` when the
  engine runs it as written.
  """
  @spec unverified(binary(), binary()) :: binary() | nil
  def unverified(pattern, op) do
    chars = String.codepoints(pattern)

    cond do
      pattern == ".*" and String.starts_with?(op, "!") -> @everything
      backslash?(chars) -> @backslash
      String.ends_with?(op, "*") and anchored_literal?(chars) -> @anchored
      true -> nil
    end
  end

  # Whether the pattern writes a backslash as a character, anywhere (a class too: the
  # simplifier reads `[\\]` as the literal).
  @spec backslash?([binary()]) :: boolean()
  defp backslash?(["\\", "\\" | _rest]), do: true
  defp backslash?(["\\", "x" | rest]), do: hex_backslash?(rest) or backslash?(rest)
  defp backslash?(["\\", _char | rest]), do: backslash?(rest)
  defp backslash?([_char | rest]), do: backslash?(rest)
  defp backslash?([]), do: false

  # `\x{5c}` or `\x5c`; anything shorter or not hex is not a backslash.
  @spec hex_backslash?([binary()]) :: boolean()
  defp hex_backslash?(["{" | rest]),
    do: rest |> Enum.take_while(&(&1 != "}")) |> backslash_code?()

  defp hex_backslash?(rest), do: rest |> Enum.take(2) |> backslash_code?()

  @spec backslash_code?([binary()]) :: boolean()
  defp backslash_code?(digits), do: match?({0x5C, ""}, Integer.parse(Enum.join(digits), 16))

  # `^ ... $` (or `\A ... \z`) around something that reads as literals, as the engine's parser
  # reads the pattern: a flag group, a plain group, a class of one member and a count of one
  # are no part of the tree, so they are read through. Two shapes become an equality: anchors
  # around literals, and anchors around one capturing group of literals (or of an alternation
  # of them). Whatever else stands in the way (a quantifier, `.`, a class of several members, a
  # letter beside `(?i)`, a `^` or `$` under `(?m)`, a second anchor, a plain group of
  # alternatives, a capturing group beside other things) is run as written.
  @spec anchored_literal?([binary()]) :: boolean()
  defp anchored_literal?(chars) do
    case alternatives(chars, @flags, [], []) do
      {[items], _rest} -> items |> flatten() |> rewritten?()
      {_several, _rest} -> false
    end
  end

  @typep item :: :start | :end | :lit | :other | {:group, [[item()]]} | {:cap, [[item()]]}
  @typep flags :: %{ignore_case: boolean(), multi_line: boolean()}

  # The alternatives of a pattern or of a group, up to its `)` (taken) or the end of the text.
  # `items` are those of the alternative being read, last first. The pattern was read by
  # `SQLRustRegex.check/1` before this is asked, so its groups and escapes are well formed.
  @spec alternatives([binary()], flags(), [item()], [[item()]]) :: {[[item()]], [binary()]}
  defp alternatives([], _flags, items, alts), do: {finish(items, alts), []}
  defp alternatives([")" | rest], _flags, items, alts), do: {finish(items, alts), rest}

  defp alternatives(["|" | rest], flags, items, alts),
    do: alternatives(rest, flags, [], [Enum.reverse(items) | alts])

  defp alternatives(chars, flags, items, alts) do
    {items, flags, rest} = atom(chars, flags, items)
    alternatives(rest, flags, items, alts)
  end

  @spec finish([item()], [[item()]]) :: [[item()]]
  defp finish(items, alts), do: Enum.reverse([Enum.reverse(items) | alts])

  # One atom of the pattern: the items it leaves (last first), the flags after it and the rest.
  @spec atom([binary()], flags(), [item()]) :: {[item()], flags(), [binary()]}
  defp atom(["(", "?", ":" | rest], flags, items), do: group(rest, flags, flags, :group, items)

  defp atom(["(", "?", flag, ")" | rest], flags, items), do: {items, set_flag(flags, flag), rest}

  defp atom(["(", "?", flag, ":" | rest], flags, items),
    do: group(rest, set_flag(flags, flag), flags, :group, items)

  defp atom(["(" | rest], flags, items), do: group(rest, flags, flags, :cap, items)
  defp atom(["[" | rest], flags, items), do: class(rest, flags, items)
  defp atom(["\\", "A" | rest], flags, items), do: {[:start | items], flags, rest}
  defp atom(["\\", "z" | rest], flags, items), do: {[:end | items], flags, rest}

  defp atom(["\\", kind | rest], flags, items) when kind in ~w(b B d D w W s S p P),
    do: {[:other | items], flags, rest}

  defp atom(["\\", "x", "{" | rest], flags, items) do
    {digits, tail} = Enum.split_while(rest, &(&1 != "}"))
    {[literal(hex(digits), flags) | items], flags, Enum.drop(tail, 1)}
  end

  defp atom(["\\", "x", high, low | rest], flags, items),
    do: {[literal(hex([high, low]), flags) | items], flags, rest}

  defp atom(["\\", char | rest], flags, items),
    do: {[literal(Map.get(@controls, char, char), flags) | items], flags, rest}

  defp atom(["^" | rest], %{multi_line: false} = flags, items),
    do: {[:start | items], flags, rest}

  defp atom(["$" | rest], %{multi_line: false} = flags, items), do: {[:end | items], flags, rest}

  # Under `(?m)` they end a line, which the engine's tree does not read as the text's ends.
  defp atom([anchor | rest], %{multi_line: true} = flags, items) when anchor in ["^", "$"],
    do: {[:other | items], flags, rest}

  defp atom(["." | rest], flags, items), do: {[:other | items], flags, rest}

  defp atom([quantifier | rest], flags, items) when quantifier in ["*", "+", "?"],
    do: {[:other | Enum.drop(items, 1)], flags, rest}

  # A count: `{1}` repeats nothing, `{0}` takes what precedes it out of the tree, any other
  # count makes it a repetition; a `?` after it only makes it lazy.
  defp atom(["{" | rest], flags, items) do
    {count, tail} = Enum.split_while(rest, &(&1 != "}"))
    {apply_count(repeat(Enum.join(count)), items), flags, lazy(Enum.drop(tail, 1))}
  end

  defp atom([char | rest], flags, items), do: {[literal(char, flags) | items], flags, rest}

  @spec group([binary()], flags(), flags(), :group | :cap, [item()]) ::
          {[item()], flags(), [binary()]}
  defp group(rest, inner, outer, kind, items) do
    {alts, rest} = alternatives(rest, inner, [], [])
    {[{kind, alts} | items], outer, rest}
  end

  # `(?s)` changes how `.` reads, which no literal depends on.
  @spec set_flag(flags(), binary()) :: flags()
  defp set_flag(flags, "i"), do: %{flags | ignore_case: true}
  defp set_flag(flags, "m"), do: %{flags | multi_line: true}
  defp set_flag(flags, "s"), do: flags

  # A character is a literal unless `(?i)` is on and it has a case (the engine reads it as the
  # set of its cases then).
  @spec literal(binary(), flags()) :: :lit | :other
  defp literal(char, %{ignore_case: true}), do: if(cased?(char), do: :other, else: :lit)
  defp literal(_char, %{ignore_case: false}), do: :lit

  @spec cased?(binary()) :: boolean()
  defp cased?(char), do: String.downcase(char) != char or String.upcase(char) != char

  @hex_digits ~w(0 1 2 3 4 5 6 7 8 9 a b c d e f)

  # The character of hex digits (`SQLRustRegex.check/1` read them as a character).
  @spec hex([binary()]) :: binary()
  defp hex(digits) do
    code =
      Enum.reduce(digits, 0, fn digit, sum ->
        sum * 16 + (Enum.find_index(@hex_digits, &(&1 == String.downcase(digit))) || 0)
      end)

    <<code::utf8>>
  end

  @spec repeat(binary()) :: :once | :zero | :many
  defp repeat(count) do
    case count |> String.split(",") |> Enum.map(&Integer.parse/1) do
      [{times, ""}] -> exactly(times)
      [{times, ""}, {times, ""}] -> exactly(times)
      _other -> :many
    end
  end

  @spec exactly(non_neg_integer()) :: :once | :zero | :many
  defp exactly(1), do: :once
  defp exactly(0), do: :zero
  defp exactly(_times), do: :many

  @spec apply_count(:once | :zero | :many, [item()]) :: [item()]
  defp apply_count(:once, items), do: items
  defp apply_count(:zero, items), do: Enum.drop(items, 1)
  defp apply_count(:many, items), do: [:other | Enum.drop(items, 1)]

  @spec lazy([binary()]) :: [binary()]
  defp lazy(["?" | rest]), do: rest
  defp lazy(rest), do: rest

  # A class is a literal when it holds one character (`[b]`, `[b-b]`, `[bb]`, `[\x62]`); a
  # negated class, and a class of several, is not.
  @spec class([binary()], flags(), [item()]) :: {[item()], flags(), [binary()]}
  defp class(["^" | chars], flags, items) do
    {_spans, rest} = spans(chars, true, [])
    {[:other | items], flags, rest}
  end

  defp class(chars, flags, items) do
    {spans, rest} = spans(chars, true, [])

    item =
      case Enum.uniq(spans) do
        [{code, code}] -> literal(<<code::utf8>>, flags)
        _several -> :other
      end

    {[item | items], flags, rest}
  end

  # The spans of a class up to its `]` (taken; a `]` that comes first is a member): a character
  # is the span of its code point, a range of the two ends, and `\d` and its kin the span of
  # every code point.
  @spec spans([binary()], boolean(), [{non_neg_integer(), non_neg_integer()}]) ::
          {[{non_neg_integer(), non_neg_integer()}], [binary()]}
  defp spans(["]" | rest], false, acc), do: {acc, rest}

  defp spans(chars, _first?, acc) do
    {low, rest} = member(chars)

    case rest do
      ["-", next | more] when next != "]" ->
        {high, rest} = member([next | more])
        spans(rest, false, [{elem(low, 0), elem(high, 1)} | acc])

      _no_range ->
        spans(rest, false, [low | acc])
    end
  end

  @everything_span {0, 0x10FFFF}

  @spec member([binary()]) :: {{non_neg_integer(), non_neg_integer()}, [binary()]}
  defp member(["\\", set | rest]) when set in ~w(d D w W s S), do: {@everything_span, rest}

  defp member(["\\", "x", high, low | rest]), do: {span(hex([high, low])), rest}

  defp member(["\\", char | rest]), do: {span(Map.get(@controls, char, char)), rest}
  defp member([char | rest]), do: {span(char), rest}

  @spec span(binary()) :: {non_neg_integer(), non_neg_integer()}
  defp span(<<code::utf8>>), do: {code, code}

  # Plain groups are no node of the engine's tree, their items stand in their place; a plain
  # group of alternatives is not a literal.
  @spec flatten([item()]) :: [item()]
  defp flatten(items), do: Enum.flat_map(items, &flat/1)

  @spec flat(item()) :: [item()]
  defp flat({:group, [alternative]}), do: flatten(alternative)
  defp flat({:group, _several}), do: [:other]
  defp flat({:cap, alternatives}), do: [{:cap, Enum.map(alternatives, &flatten/1)}]
  defp flat(item), do: [item]

  @spec rewritten?([item()]) :: boolean()
  defp rewritten?([:start | rest]) do
    case Enum.split(rest, -1) do
      {middle, [:end]} -> literal_body?(middle)
      _no_end -> false
    end
  end

  defp rewritten?(_items), do: false

  @spec literal_body?([item()]) :: boolean()
  defp literal_body?([{:cap, alternatives}]), do: Enum.all?(alternatives, &literals?/1)
  defp literal_body?(middle), do: literals?(middle)

  @spec literals?([item()]) :: boolean()
  defp literals?(items), do: items != [] and Enum.all?(items, &(&1 == :lit))
end
