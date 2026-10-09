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
  #
  # A pattern that is such an equality is declined for `~*` and `!~*` only when a literal
  # holds a cased character (one whose upcase or downcase differs from it): with none, the
  # equality and the case folding keep the same rows (`^2023$`, `^1$`, `^(?i)1$`).
  #
  # Preconditions: the pattern passed `SQLRustRegex.check/1`. The module does not rely on it
  # to be total, though: an unknown flag leaves the flags as they are, and a `\x` escape that
  # is no character (a surrogate, a code beyond Unicode) is no literal, whatever the reader.

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

  @typep item ::
           :start | :end | :lit | :cased | :other | {:group, [[item()]]} | {:cap, [[item()]]}
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

  # `(?s)` changes how `.` reads, which no literal depends on; any other flag leaves the flags
  # as they are.
  @spec set_flag(flags(), binary()) :: flags()
  defp set_flag(flags, flag) do
    case flag do
      "i" -> %{flags | ignore_case: true}
      "m" -> %{flags | multi_line: true}
      _other -> flags
    end
  end

  # What a character is: a literal with no case (`:lit`), a literal with a case (`:cased`), or
  # not a literal (`:other`: nothing, or a character that has a case while `(?i)` is on, which
  # the engine reads as the set of its cases). Keyed by `{is a character, has a case, (?i)}`.
  @kinds %{
    {false, false, false} => :other,
    {false, false, true} => :other,
    {true, false, false} => :lit,
    {true, false, true} => :lit,
    {true, true, false} => :cased,
    {true, true, true} => :other
  }

  @spec literal(binary() | nil, flags()) :: :lit | :cased | :other
  defp literal(char, flags) do
    character? = is_binary(char)
    Map.fetch!(@kinds, {character?, character? and cased?(char), flags.ignore_case})
  end

  @spec cased?(binary()) :: boolean()
  defp cased?(char), do: String.downcase(char) != char or String.upcase(char) != char

  @hex_digits ~w(0 1 2 3 4 5 6 7 8 9 a b c d e f)

  # The character of hex digits, or `nil` when they are no character (a surrogate or a code
  # beyond Unicode), which is no literal.
  @spec hex([binary()]) :: binary() | nil
  defp hex(digits) do
    code =
      Enum.reduce(digits, 0, fn digit, sum ->
        sum * 16 + (Enum.find_index(@hex_digits, &(&1 == String.downcase(digit))) || 0)
      end)

    if code in 0..0x10FFFF and code not in 0xD800..0xDFFF, do: <<code::utf8>>
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
  # A class the pattern leaves open (`D[$[`; `SQLRustRegex.check/1` refuses it first) is no
  # literal: total without that check.
  defp spans([], _first?, acc), do: {[{0, 0x10FFFF} | acc], []}

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

  # A character that is none (see `hex/1`) stands for every code point: no class of one.
  @spec span(binary() | nil) :: {non_neg_integer(), non_neg_integer()}
  defp span(char) do
    for(<<code::utf8 <- to_string(char)>>, do: code)
    |> Enum.reduce(@everything_span, fn code, _span -> {code, code} end)
  end

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
  defp literal_body?([{:cap, alternatives}]), do: cased_literals?(alternatives)
  defp literal_body?(middle), do: cased_literals?([middle])

  # The equality loses nothing to the operator's case folding when no character has a case
  # (`^2023$`: the rows equal to the text are the rows that match it in any case), so only
  # literals that hold a cased character are the ones the double declines.
  @spec cased_literals?([[item()]]) :: boolean()
  defp cased_literals?(alternatives),
    do: Enum.all?(alternatives, &literals?/1) and Enum.any?(alternatives, &(:cased in &1))

  @spec literals?([item()]) :: boolean()
  defp literals?(items), do: items != [] and Enum.all?(items, &(&1 in [:lit, :cased]))
end
