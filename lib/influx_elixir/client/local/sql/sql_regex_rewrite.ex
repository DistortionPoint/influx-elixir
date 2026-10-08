defmodule InfluxElixir.Client.Local.SQLRegexRewrite do
  @moduledoc false
  # The patterns the engine's simplifier rewrites before it runs them, in ways that are not the
  # regular expression's own meaning (verified against InfluxDB 3 Core 3.10.1, each shape below
  # on a table of case variants):
  #
  #   * a pattern that is nothing but literals between `^` and `$` (also `^(abc)$`, `^(?:abc)$`,
  #     `^[a]bc$`, `^ab{1}$`, `\Aabc\z`, and an alternation of literals in a group,
  #     `^(abc|ABC)$`) becomes an equality, which `~*` and `!~*` lose their case folding to:
  #     `s ~* '^abc$'` keeps only the rows equal to `abc`. A pattern the simplifier does not read
  #     as a literal is run as written (`^abc` and `abc$`, `^a.c$`, `^a[bB]$`, `(?i)^abc$`,
  #     `^ab1?$`, `^ab\b$`, `^ab$|^a b$`)
  #   * a pattern of literals that holds a backslash (`\\`, `\x5c`, `[\\]`) becomes a `LIKE`
  #     whose escape character is that backslash: `s ~ '\\'` keeps the strings that end in `%`,
  #     `s ~ '\\ '` those that hold a space
  #   * `.*` under a negation: `s !~ '.*'` and `NOT (s ~ '.*')` are answered as tests of the
  #     value's being empty or null, where the regular expression says none
  #
  # The double does not model the rewrite, so a pattern that may be one of these is refused by
  # name (`unverified/2`); a pattern the rewrite leaves alone is run as written. The reader only
  # tells a pattern that may be a literal; it does not tell one the simplifier declines.

  @backslash "a literal backslash (the engine turns a pattern of literals into a LIKE and " <>
               "leaves the backslash its escape)"
  @everything "the pattern .* (the engine rewrites it, and the rewrite is not the " <>
                "expression's own meaning under a negation)"
  @anchored "an anchored literal beside a case-insensitive operator (the engine rewrites it " <>
              "to an equality that ignores the operator's case folding)"

  @doc """
  Why the double declines a pattern for the operator (`~`, `~*`, `!~`, `!~*`), or `nil` when the
  engine runs it as written.
  """
  @spec unverified(binary(), binary()) :: binary() | nil
  def unverified(pattern, op) do
    chars = String.codepoints(pattern)

    cond do
      pattern == ".*" -> @everything
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

  # `^ ... $` (or `\A ... \z`) around something that reads as literals, groups of them and
  # alternations of them in a group.
  @spec anchored_literal?([binary()]) :: boolean()
  defp anchored_literal?(chars) do
    with {:ok, rest} <- opening(chars),
         {:ok, body} <- closing(rest) do
      body != [] and literal?(body, 0)
    else
      :error -> false
    end
  end

  @spec opening([binary()]) :: {:ok, [binary()]} | :error
  defp opening(["^" | rest]), do: {:ok, rest}
  defp opening(["\\", "A" | rest]), do: {:ok, rest}
  defp opening(_chars), do: :error

  @spec closing([binary()]) :: {:ok, [binary()]} | :error
  defp closing(chars) do
    case Enum.reverse(chars) do
      ["$" | rest] -> unescaped(rest)
      ["z", "\\" | rest] -> unescaped(rest)
      _other -> :error
    end
  end

  # What stands before the closing anchor, unless its backslashes escape the anchor.
  @spec unescaped([binary()]) :: {:ok, [binary()]} | :error
  defp unescaped(reversed) do
    slashes = reversed |> Enum.take_while(&(&1 == "\\")) |> length()
    if rem(slashes, 2) == 0, do: {:ok, Enum.reverse(reversed)}, else: :error
  end

  # Whether the characters are literals; `depth` is how many groups are open (an alternation
  # outside a group is two patterns, which the simplifier does not read as one literal).
  @spec literal?([binary()], non_neg_integer()) :: boolean()
  # A group left open, or a `)` with none open, is not a literal (the syntax check refuses
  # both before this is asked; the answer keeps the reading total).
  defp literal?([], depth), do: depth == 0
  defp literal?(["(", "?", ":" | rest], depth), do: literal?(rest, depth + 1)
  defp literal?(["(", "?" | _rest], _depth), do: false
  defp literal?(["(" | rest], depth), do: literal?(rest, depth + 1)
  defp literal?([")" | rest], depth), do: depth > 0 and literal?(rest, depth - 1)
  defp literal?(["|" | _rest], 0), do: false
  defp literal?(["|" | rest], depth), do: literal?(rest, depth)

  defp literal?(["[", char, "]" | rest], depth) when char not in ["^", "\\"],
    do: literal?(rest, depth)

  defp literal?(["[" | _rest], _depth), do: false

  defp literal?(["\\", escape | _rest], _depth) when escape in ~w(A z b B w W d D s S p P G Z),
    do: false

  defp literal?(["\\", _escape | rest], depth), do: literal?(rest, depth)

  defp literal?([char | _rest], _depth) when char in [".", "*", "+", "?", "^", "$"], do: false
  defp literal?([_char | rest], depth), do: literal?(rest, depth)
end
