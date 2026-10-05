defmodule InfluxElixir.Client.Local.SQLRustRegex do
  @moduledoc false
  # The error the engine's regular expression crate gives a pattern it cannot compile, for the
  # `~` operators of `InfluxElixir.Client.Local` (verified against InfluxDB 3 Core, each message
  # below on a pattern of its own).
  #
  # The double matches with PCRE, whose syntax is not the crate's: PCRE accepts look-around,
  # back references and `\Z`, which the crate refuses, and words its own errors differently.
  # The engine's error names the pattern and the place of the fault:
  #
  #     regex parse error:
  #         a{2,1}
  #          ^^^^^
  #     error: invalid repetition count range, the start must be <= the end
  #
  # This reads a pattern left to right as the crate's parser does, and stops at the first
  # fault it knows the words of. A pattern it reads to the end is `:ok`; one that holds a
  # construct it does not read (a flag group, a nested class, a `\x` escape, a pattern of several
  # lines) is `:unknown`, which the caller answers with PCRE's own verdict (and a refusal by
  # name for a pattern PCRE rejects).
  #
  # Whether a Unicode property exists is PCRE's answer; the crate's names are the same ones.

  @escapes ~c"dDwWsSbBAzntrfva"
  @class_escapes ~c"dDwWsSntrfva"

  @doc "The engine's error text for the pattern, `:ok` for a pattern it compiles, else `:unknown`."
  @spec check(binary()) :: :ok | :unknown | :differs | {:error, binary()}
  def check(pattern) do
    if String.contains?(pattern, ["\n", "\r"]) do
      :unknown
    else
      chars = String.codepoints(pattern)

      case scan(chars, 0, length(chars), [], false) do
        :ok -> :ok
        :unknown -> :unknown
        :differs -> :differs
        {:error, start, stop, message} -> {:error, format(pattern, start, stop, message)}
      end
    end
  end

  @spec format(binary(), non_neg_integer(), non_neg_integer(), binary()) :: binary()
  defp format(pattern, start, stop, message) do
    pointer = String.duplicate(" ", start) <> String.duplicate("^", max(stop - start, 1))
    "regex parse error:\n    #{pattern}\n    #{pointer}\nerror: #{message}"
  end

  # `groups` are the starts of the groups still open, `atom?` says something to repeat precedes.
  @spec scan([binary()], non_neg_integer(), non_neg_integer(), [non_neg_integer()], boolean()) ::
          :ok | :unknown | :differs | {:error, non_neg_integer(), non_neg_integer(), binary()}
  defp scan([], _at, _length, [], _atom?), do: :ok

  defp scan([], _at, _length, [start | _open], _atom?),
    do: {:error, start, start + 1, "unclosed group"}

  defp scan(["\\" | rest], at, length, groups, _atom?),
    do: escape(rest, at, length, groups)

  defp scan(["(" | rest], at, length, groups, _atom?) do
    case group(rest, at) do
      {:error, _start, _stop, _message} = error -> error
      :unknown -> :unknown
      {:ok, taken} -> scan(Enum.drop(rest, taken), at + 1 + taken, length, [at | groups], false)
    end
  end

  defp scan([")" | _rest], at, _length, [], _atom?),
    do: {:error, at, at + 1, "unopened group"}

  defp scan([")" | rest], at, length, [_group | groups], _atom?),
    do: scan(rest, at + 1, length, groups, true)

  defp scan(["|" | rest], at, length, groups, _atom?),
    do: scan(rest, at + 1, length, groups, false)

  defp scan(["[" | rest], at, length, groups, _atom?), do: class(rest, at, length, groups)

  defp scan([operator | _rest], at, _length, _groups, false) when operator in ["*", "+", "?"],
    do: {:error, at, at + 1, "repetition operator missing expression"}

  defp scan([operator | rest], at, length, groups, true) when operator in ["*", "+", "?"],
    do: scan(rest, at + 1, length, groups, true)

  defp scan(["{" | rest], at, length, groups, atom?) do
    case counted(rest) do
      {:ok, taken, low, high} ->
        cond do
          not atom? -> {:error, at, at + 1, "repetition operator missing expression"}
          high != nil and high < low -> invalid_range(at, taken)
          true -> scan(Enum.drop(rest, taken - 1), at + taken, length, groups, true)
        end

      :error ->
        if atom?, do: bad_count(rest, at), else: :unknown
    end
  end

  defp scan([_char | rest], at, length, groups, _atom?),
    do: scan(rest, at + 1, length, groups, true)

  @spec invalid_range(non_neg_integer(), pos_integer()) ::
          {:error, non_neg_integer(), non_neg_integer(), binary()}
  defp invalid_range(at, taken),
    do: {:error, at, at + taken, "invalid repetition count range, the start must be <= the end"}

  # A `{` after something to repeat that does not read as a count: the engine points at the
  # first character that is not one (`a{x}`, `a{}`, `a{,2}`), or at the whole of a count that
  # does not end (`a{1`).
  @spec bad_count([binary()], non_neg_integer()) ::
          :unknown | {:error, non_neg_integer(), non_neg_integer(), binary()}
  defp bad_count(rest, at) do
    {inner, tail} = Enum.split_while(rest, &(&1 != "}"))
    text = Enum.join(inner)
    [valid] = Regex.run(~r/\A(?:\d+(?:,\d*)?)?/, text)

    cond do
      tail == [] and valid == text ->
        {:error, at, at + 1 + length(inner), "unclosed counted repetition"}

      tail == [] ->
        :unknown

      true ->
        bad = at + 1 + String.length(valid)
        {:error, bad, bad + 1, "repetition quantifier expects a valid decimal"}
    end
  end

  # The `{n}`, `{n,}` or `{n,m}` after an opening brace: how many characters it takes with the
  # brace, and its bounds.
  @spec counted([binary()]) ::
          {:ok, pos_integer(), non_neg_integer(), non_neg_integer() | nil} | :error
  defp counted(rest) do
    {inner, tail} = Enum.split_while(rest, &(&1 != "}"))

    with ["}" | _more] <- tail,
         [low | bound] <-
           Regex.run(~r/\A(\d+)(?:(,)(\d*))?\z/, Enum.join(inner), capture: :all_but_first) do
      high =
        case bound do
          [] -> low
          [",", ""] -> nil
          [",", digits] -> digits
        end

      {:ok, length(inner) + 2, String.to_integer(low), high && String.to_integer(high)}
    else
      _no_count -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # Groups
  # ---------------------------------------------------------------------------

  # What follows a `(`: the characters of the group's opening that are not the group's contents.
  @spec group([binary()], non_neg_integer()) ::
          {:ok, non_neg_integer()}
          | :unknown
          | {:error, non_neg_integer(), non_neg_integer(), binary()}
  defp group(["?", bang | _rest], at) when bang in ["=", "!"],
    do: {:error, at, at + 3, look_around()}

  defp group(["?", "<", bang | _rest], at) when bang in ["=", "!"],
    do: {:error, at, at + 4, look_around()}

  defp group(["?", ":" | _rest], _at), do: {:ok, 2}
  defp group(["?" | _rest], _at), do: :unknown
  defp group(_plain, _at), do: {:ok, 0}

  @spec look_around() :: binary()
  defp look_around, do: "look-around, including look-ahead and look-behind, is not supported"

  # ---------------------------------------------------------------------------
  # Escapes
  # ---------------------------------------------------------------------------

  # The escape after a backslash that stood at `at`.
  @spec escape([binary()], non_neg_integer(), non_neg_integer(), [non_neg_integer()]) ::
          :ok | :unknown | :differs | {:error, non_neg_integer(), non_neg_integer(), binary()}
  defp escape([], at, _length, _groups),
    do: {:error, at, at + 1, "incomplete escape sequence, reached end of pattern prematurely"}

  defp escape([property | rest], at, length, groups) when property in ["p", "P"] do
    case unicode(property, rest, at, length) do
      {:ok, taken} -> scan(Enum.drop(rest, taken), at + 2 + taken, length, groups, true)
      other -> other
    end
  end

  defp escape([<<digit>> | _rest], at, _length, _groups) when digit in ?0..?9,
    do: {:error, at, at + 2, "backreferences are not supported"}

  defp escape([<<letter>> | rest], at, length, groups) when letter in @escapes,
    do: scan(rest, at + 2, length, groups, true)

  defp escape([<<letter>> | _rest], _at, _length, _groups) when letter in ~c"xuU", do: :unknown

  defp escape([<<letter>> | _rest], at, _length, _groups)
       when letter in ?a..?z or letter in ?A..?Z,
       do: {:error, at, at + 2, "unrecognized escape sequence"}

  defp escape([<<char>> | _rest], _at, _length, _groups) when char in [?<, ?>], do: :differs

  defp escape([_punctuation | rest], at, length, groups),
    do: scan(rest, at + 2, length, groups, true)

  # `\p{Name}` or `\pL`: the property exists when PCRE has it.
  @spec unicode(binary(), [binary()], non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()}
          | :unknown
          | {:error, non_neg_integer(), non_neg_integer(), binary()}
  defp unicode(_kind, [], _at, length),
    do:
      {:error, length, length + 1,
       "incomplete escape sequence, reached end of pattern prematurely"}

  defp unicode(kind, ["{" | rest], at, length) do
    {name, tail} = Enum.split_while(rest, &(&1 != "}"))

    case tail do
      [] ->
        {:error, length, length + 1,
         "incomplete escape sequence, reached end of pattern prematurely"}

      ["}" | _more] ->
        taken = Enum.count(name) + 2
        property(kind, "{" <> Enum.join(name) <> "}", name, at, taken)
    end
  end

  defp unicode(kind, [letter | _rest], at, _length),
    do: property(kind, letter, [letter], at, 1)

  @spec property(binary(), binary(), [binary()], non_neg_integer(), pos_integer()) ::
          {:ok, pos_integer()}
          | {:error, non_neg_integer(), non_neg_integer(), binary()}
  defp property(kind, spelled, name, at, taken) do
    if match?({:ok, _regex}, Regex.compile("\\" <> kind <> spelled, "u")) do
      {:ok, taken}
    else
      {:error, at, at + 2 + taken, missing(name)}
    end
  end

  # `\p{Script=Foo}` names a property that exists and a value that does not.
  @spec missing([binary()]) :: binary()
  defp missing(name) do
    text = Enum.join(name)

    case String.split(text, ["=", ":"], parts: 2) do
      [key, _value] ->
        if match?({:ok, _regex}, Regex.compile("\\p{" <> key <> "=Any}", "u")) or key_known?(key),
          do: "Unicode property value not found",
          else: "Unicode property not found"

      _plain ->
        "Unicode property not found"
    end
  end

  @spec key_known?(binary()) :: boolean()
  defp key_known?(key) do
    String.downcase(key) in ~w(script sc script_extensions scx general_category gc age)
  end

  # ---------------------------------------------------------------------------
  # Character classes
  # ---------------------------------------------------------------------------

  # The class after a `[` that stood at `at`, read to its end.
  @spec class([binary()], non_neg_integer(), non_neg_integer(), [non_neg_integer()]) ::
          :ok | :unknown | :differs | {:error, non_neg_integer(), non_neg_integer(), binary()}
  defp class(rest, at, length, groups) do
    {negated, body} = if match?(["^" | _more], rest), do: {1, tl(rest)}, else: {0, rest}

    # A `]` first in the class is a literal.
    {first, body} =
      case body do
        ["]" | more] -> {["]"], more}
        other -> {[], other}
      end

    case class_items(body, at + 1 + negated + length(first)) do
      {:ok, taken} ->
        scan(
          Enum.drop(body, taken),
          at + 1 + negated + length(first) + taken,
          length,
          groups,
          true
        )

      :unclosed ->
        {:error, at, at + 1, "unclosed character class"}

      other ->
        other
    end
  end

  # The characters of a class up to its `]` (taken with it), checking its ranges.
  @spec class_items([binary()], non_neg_integer()) ::
          {:ok, non_neg_integer()}
          | :unclosed
          | :unknown
          | {:error, non_neg_integer(), non_neg_integer(), binary()}
  defp class_items(chars, at), do: class_items(chars, at, 0)

  defp class_items([], _at, _taken), do: :unclosed
  defp class_items(["]" | _rest], _at, taken), do: {:ok, taken + 1}
  defp class_items(["[" | _rest], _at, _taken), do: :unknown

  defp class_items([operator, operator | _rest], _at, _taken) when operator in ["&", "-", "~"],
    do: :unknown

  defp class_items(["\\", <<letter>>, "-", high | _rest], at, _taken)
       when letter in ~c"dDwWsS" and high != "]",
       do: {:error, at, at + 2, "invalid range boundary, must be a literal"}

  defp class_items([low, "-", "\\", <<letter>> | _rest], at, _taken)
       when low != "\\" and letter in ~c"dDwWsS",
       do: {:error, at + 2, at + 4, "invalid range boundary, must be a literal"}

  defp class_items(["\\", <<letter>> | rest], at, taken) when letter in @class_escapes,
    do: class_items(rest, at + 2, taken + 2)

  defp class_items(["\\", <<digit>> | _rest], at, _taken) when digit in ?0..?9,
    do: {:error, at, at + 2, "backreferences are not supported"}

  defp class_items(["\\", <<letter>> | _rest], at, _taken)
       when letter in ?a..?z or letter in ?A..?Z do
    if letter in ~c"bBAzxuUpPQEG",
      do: :unknown,
      else: {:error, at, at + 2, "unrecognized escape sequence"}
  end

  defp class_items(["\\", _punctuation | rest], at, taken),
    do: class_items(rest, at + 2, taken + 2)

  defp class_items(["\\"], _at, _taken), do: :unknown

  defp class_items([low, "-", high | rest], at, taken)
       when high not in ["]", "\\", "["] and low not in ["\\", "-"] do
    if low > high do
      {:error, at, at + 3, "invalid character class range, the start must be <= the end"}
    else
      class_items(rest, at + 3, taken + 3)
    end
  end

  defp class_items([_char | rest], at, taken), do: class_items(rest, at + 1, taken + 1)
end
