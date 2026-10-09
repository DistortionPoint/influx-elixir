defmodule InfluxElixir.Client.Local.InfluxQLBlankRegex do
  @moduledoc false
  # The one blank of InfluxQL as a piece of a regular expression, for the patterns that read
  # statements. Everything here runs when those patterns are compiled, not when a statement is
  # read, so it is left out of the coverage count (`mix.exs`); what it produces is exercised by
  # every InfluxQL contract case.
  #
  # The blank is a space, a tab, a carriage return and a line feed. PCRE's own `\s` also takes a
  # vertical tab and a form feed, which the engine does not (verified: `SHOW TAG\vKEYS` is
  # "expected KEYS or VALUES"), so no pattern that reads a statement may use `\s`: `sigil_q` (a
  # `~r` that reads `\s` and `\S` as the blank) and `blank_pattern/1` (the same for a pattern
  # held in a string) are how they get it.

  @blank "[ \\t\\r\\n]"
  @blank_chars " \\t\\r\\n"
  @not_blank "[^ \\t\\r\\n]"

  @doc "The regular expression piece for one blank."
  @spec blank() :: binary()
  def blank, do: @blank

  @doc """
  The pattern with its `\\s` and `\\S` read as the language's blank (see `sigil_q/2`).

  Only the constructs that are handled faithfully are rewritten. A construct that would still
  match a vertical tab or a form feed, or that this function does not read (a `\\S` in a
  bracket class, a POSIX class, `\\R`, `\\h`, `\\v`, `\\Q...\\E`, `\\p{Z}`, the extended `x`
  mode), raises `ArgumentError`: it fails the build that holds the pattern, never a query.
  """
  @spec blank_pattern(binary()) :: binary()
  def blank_pattern(pattern), do: pattern |> rewrite(:out, []) |> IO.iodata_to_binary()

  @unhandled_escapes [?Q, ?R, ?h, ?H, ?v, ?V]

  # `:out` is outside a bracket class, `:start` just after its `[` or `[^` (a `]` there is a
  # member, not the end), `:in` inside it.
  defp rewrite(<<>>, :out, acc), do: Enum.reverse(acc)
  defp rewrite(<<>>, _state, _acc), do: unhandled("an unterminated bracket class")

  defp rewrite(<<"\\", c, _rest::binary>>, _state, _acc) when c in @unhandled_escapes,
    do: unhandled(<<?\\, c>>)

  defp rewrite(<<"\\S", _rest::binary>>, state, _acc) when state != :out,
    do: unhandled("\\S inside a bracket class")

  defp rewrite(<<"\\s", rest::binary>>, :out, acc), do: rewrite(rest, :out, [@blank | acc])
  defp rewrite(<<"\\S", rest::binary>>, :out, acc), do: rewrite(rest, :out, [@not_blank | acc])

  defp rewrite(<<"\\s", rest::binary>>, _in, acc), do: rewrite(rest, :in, [@blank_chars | acc])

  defp rewrite(<<"\\", c::utf8, rest::binary>>, state, acc) do
    if c in [?p, ?P] and Regex.match?(~r/\A(?:\{(?:Z\}|Xsp\}|Xps\})|Z)/, rest),
      do: unhandled(<<?\\, c>> <> "{Z}")

    rewrite(rest, next(state), [<<?\\, c::utf8>> | acc])
  end

  defp rewrite(<<"(?", rest::binary>>, :out, acc) do
    if Regex.match?(~r/\A[a-zA-Z]*x/, rest),
      do: unhandled("the extended mode (?x)"),
      else: rewrite(rest, :out, ["(?" | acc])
  end

  defp rewrite(<<"[:", _rest::binary>>, state, _acc) when state != :out,
    do: unhandled("a POSIX bracket class")

  defp rewrite(<<"[^", rest::binary>>, :out, acc), do: rewrite(rest, :start, ["[^" | acc])
  defp rewrite(<<"[", rest::binary>>, :out, acc), do: rewrite(rest, :start, ["[" | acc])
  defp rewrite(<<"]", rest::binary>>, :start, acc), do: rewrite(rest, :in, ["]" | acc])
  defp rewrite(<<"]", rest::binary>>, :in, acc), do: rewrite(rest, :out, ["]" | acc])

  defp rewrite(<<c::utf8, rest::binary>>, state, acc),
    do: rewrite(rest, next(state), [<<c::utf8>> | acc])

  defp rewrite(<<c, rest::binary>>, state, acc), do: rewrite(rest, next(state), [<<c>> | acc])

  defp next(:start), do: :in
  defp next(state), do: state

  defp unhandled(what) do
    raise ArgumentError,
          "InfluxQLBlankRegex cannot rewrite #{inspect(what)}: write the blank of the " <>
            "language out as [ \\t\\r\\n] (or extend blank_pattern/1 and verify it against Core)"
  end

  @doc """
  A `~r` whose `\\s` and `\\S` are the language's blank and its complement (see `blank/0`):
  every regular expression that reads a statement is written `~q/.../`. A pattern that
  `blank_pattern/1` cannot rewrite, or the `x` modifier, fails the compile.
  """
  defmacro sigil_q({:<<>>, meta, parts}, modifiers) do
    if ?x in modifiers, do: unhandled("the x modifier")

    parts =
      Enum.map(parts, fn part -> if is_binary(part), do: blank_pattern(part), else: part end)

    {:sigil_r, meta, [{:<<>>, meta, parts}, modifiers]}
  end
end
