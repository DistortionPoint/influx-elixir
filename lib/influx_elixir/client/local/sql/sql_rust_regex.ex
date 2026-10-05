defmodule InfluxElixir.Client.Local.SQLRustRegex do
  @moduledoc false
  # The error the engine's regular expression crate gives a pattern it cannot compile, for the
  # `~` operators of `InfluxElixir.Client.Local` (verified against InfluxDB 3 Core, each message
  # below on a pattern of its own).
  #
  # The double matches with PCRE, whose syntax is not the crate's: PCRE accepts look-around,
  # back references and `\Z`, which the crate refuses, words its own errors differently, and
  # reads constructs the crate reads another way (`[a&&b]`, `\b{start}`, `\p{Greek}`, which is
  # the script extensions in PCRE). The engine's error names the pattern and the place of the
  # fault:
  #
  #     regex parse error:
  #         a{2,1}
  #          ^^^^^
  #     error: invalid repetition count range, the start must be <= the end
  #
  # This reads a pattern left to right as the crate's parser does, and stops at the first
  # fault it knows the words of. A pattern it reads to the end is `:ok`, and PCRE's match is
  # the engine's. A pattern that holds a construct it does not read is `{:unknown, cause}`,
  # which the caller refuses by name, whatever PCRE says of it: the double does not know what
  # the crate does with it. What it reads is:
  #
  #   * groups: `(...)`, `(?:...)` and the flag groups `(?i)`, `(?s)`, `(?m)`, `(?i:...)`,
  #     `(?s:...)` and `(?m:...)`; every other `(?` is not read
  #   * escapes: the letters of `@escapes`, `\x` with exactly two hex digits or `{hex}`, a
  #     punctuation mark, and `\p` / `\P` of a general category (`@categories`) or of one of the
  #     names the engine is known to refuse (`@refused`); not `\b{...}`, `\u`, `\U` or the
  #     name of a script (PCRE reads the script extensions, the crate the script)
  #   * classes: a literal, a range, `\d` and its kin, `\x` of two hex digits; not a nested
  #     class (`[[:alpha:]]`, which is ASCII to the crate) or an operator (`&&`, `--`, `~~`)
  #   * a brace after something to repeat that is a count (`a{2,3}`) or a fault the crate
  #     words; a brace that is neither is not read
  #   * a pattern of several lines is not read

  @escapes ~c"dDwWsSbBAzntrfva"
  @class_escapes ~c"dDwWsSntrfva"

  # The general categories PCRE and the crate read alike. Not `C`, `Cn` or `Cs` (their members
  # depend on the version of Unicode, and the crate has no `Cs`), not the scripts, the long names
  # (`Letter`), `gc=L` or `IsLatin`, which PCRE does not read.
  @categories ~w(L Lu Ll Lt Lm Lo M Mn Mc Me N Nd Nl No P Pc Pd Ps Pe Pi Pf Po S Sm Sc Sk So
    Z Zs Zl Zp Cc Cf Co)
  @single ~w(L M N P S Z)

  # Names the engine refuses, each read on Core: a name that is no property, a key with a value
  # that is none, a key that is none.
  @refused ["Foo", "Script=Foo", "Foo=Bar"]

  @several_lines "a pattern of several lines"
  @brace "a brace that is not a repetition count"
  @group "a group other than (?:...) and the flag groups (?i) (?s) (?m)"
  @flag_repeat "a repetition operator after a flag group"
  @escape "an escape the double does not read (\\u, \\U, \\x without two hex digits, \\b{...})"
  @class_escape "an escape in a character class the double does not read"
  @nested_class "a nested character class"
  @class_operator "a character class operator (&&, -- or ~~)"
  @property "a Unicode property the double has not verified"

  @typep error :: {:error, non_neg_integer(), non_neg_integer(), binary()}
  @typep verdict :: :ok | {:unknown, binary()} | :differs | error()

  @doc """
  The engine's error text for the pattern, `:ok` for a pattern it compiles, `:differs` for one
  PCRE reads another way, else `{:unknown, cause}`.
  """
  @spec check(binary()) :: :ok | {:unknown, binary()} | :differs | {:error, binary()}
  def check(pattern) do
    if String.contains?(pattern, ["\n", "\r"]) do
      {:unknown, @several_lines}
    else
      chars = String.codepoints(pattern)

      case scan(chars, 0, length(chars), [], false) do
        {:error, start, stop, message} -> {:error, format(pattern, start, stop, message)}
        verdict -> verdict
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
          verdict()
  defp scan([], _at, _length, [], _atom?), do: :ok

  defp scan([], _at, _length, [start | _open], _atom?),
    do: {:error, start, start + 1, "unclosed group"}

  defp scan(["\\" | rest], at, length, groups, _atom?),
    do: escape(rest, at, length, groups)

  defp scan(["(" | rest], at, length, groups, _atom?) do
    case group(rest, at) do
      {:error, _start, _stop, _message} = error ->
        error

      {:unknown, _cause} = unknown ->
        unknown

      {:ok, taken} ->
        scan(Enum.drop(rest, taken), at + 1 + taken, length, [at | groups], false)

      :flags ->
        flags(Enum.drop(rest, 3), at + 4, length, groups)
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
        if atom?, do: bad_count(rest, at), else: {:unknown, @brace}
    end
  end

  defp scan([_char | rest], at, length, groups, _atom?),
    do: scan(rest, at + 1, length, groups, true)

  # What follows a flag group, which sets flags and repeats nothing.
  @spec flags([binary()], non_neg_integer(), non_neg_integer(), [non_neg_integer()]) ::
          verdict()
  defp flags([operator | _rest], _at, _length, _groups) when operator in ["*", "+", "?", "{"],
    do: {:unknown, @flag_repeat}

  defp flags(rest, at, length, groups), do: scan(rest, at, length, groups, false)

  @spec invalid_range(non_neg_integer(), pos_integer()) :: error()
  defp invalid_range(at, taken),
    do: {:error, at, at + taken, "invalid repetition count range, the start must be <= the end"}

  # A `{` after something to repeat that does not read as a count: the engine points at the
  # first character that is not one (`a{x}`, `a{}`, `a{,2}`), or at the whole of a count that
  # does not end (`a{1`).
  @spec bad_count([binary()], non_neg_integer()) :: {:unknown, binary()} | error()
  defp bad_count(rest, at) do
    {inner, tail} = Enum.split_while(rest, &(&1 != "}"))
    text = Enum.join(inner)
    [valid] = Regex.run(~r/\A(?:\d+(?:,\d*)?)?/, text)

    cond do
      tail == [] and valid == text ->
        {:error, at, at + 1 + length(inner), "unclosed counted repetition"}

      tail == [] ->
        {:unknown, @brace}

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

  # What follows a `(`: the characters of the group's opening that are not the group's contents,
  # or `:flags` for a flag group that closes at once.
  @spec group([binary()], non_neg_integer()) ::
          {:ok, non_neg_integer()} | :flags | {:unknown, binary()} | error()
  defp group(["?", bang | _rest], at) when bang in ["=", "!"],
    do: {:error, at, at + 3, look_around()}

  defp group(["?", "<", bang | _rest], at) when bang in ["=", "!"],
    do: {:error, at, at + 4, look_around()}

  defp group(["?", ":" | _rest], _at), do: {:ok, 2}
  defp group(["?", flag, ")" | _rest], _at) when flag in ["i", "s", "m"], do: :flags
  defp group(["?", flag, ":" | _rest], _at) when flag in ["i", "s", "m"], do: {:ok, 3}
  defp group(["?" | _rest], _at), do: {:unknown, @group}
  defp group(_plain, _at), do: {:ok, 0}

  @spec look_around() :: binary()
  defp look_around, do: "look-around, including look-ahead and look-behind, is not supported"

  # ---------------------------------------------------------------------------
  # Escapes
  # ---------------------------------------------------------------------------

  # The escape after a backslash that stood at `at`.
  @spec escape([binary()], non_neg_integer(), non_neg_integer(), [non_neg_integer()]) ::
          verdict()
  defp escape([], at, _length, _groups),
    do: {:error, at, at + 1, "incomplete escape sequence, reached end of pattern prematurely"}

  defp escape([property | rest], at, length, groups) when property in ["p", "P"] do
    case unicode(property, rest, at, length) do
      {:ok, taken} -> scan(Enum.drop(rest, taken), at + 2 + taken, length, groups, true)
      other -> other
    end
  end

  defp escape(["x" | rest], at, length, groups) do
    case hex(rest) do
      {:ok, taken} -> scan(Enum.drop(rest, taken), at + 2 + taken, length, groups, true)
      :error -> {:unknown, @escape}
    end
  end

  defp escape([<<digit>> | _rest], at, _length, _groups) when digit in ?0..?9,
    do: {:error, at, at + 2, "backreferences are not supported"}

  defp escape([<<letter>>, "{" | _rest], _at, _length, _groups) when letter in ~c"bB",
    do: {:unknown, @escape}

  defp escape([<<letter>> | rest], at, length, groups) when letter in @escapes,
    do: scan(rest, at + 2, length, groups, true)

  defp escape([<<letter>> | _rest], _at, _length, _groups) when letter in ~c"uU",
    do: {:unknown, @escape}

  defp escape([<<letter>> | _rest], at, _length, _groups)
       when letter in ?a..?z or letter in ?A..?Z,
       do: {:error, at, at + 2, "unrecognized escape sequence"}

  defp escape([<<char>> | _rest], _at, _length, _groups) when char in [?<, ?>], do: :differs

  defp escape([_punctuation | rest], at, length, groups),
    do: scan(rest, at + 2, length, groups, true)

  # What follows `\x` when it is a character: two hex digits, or hex digits in braces that are a
  # code point (how many characters are taken after the `x`).
  @spec hex([binary()]) :: {:ok, pos_integer()} | :error
  defp hex([high, low | _more] = rest) do
    if hex_digits?([high, low]), do: {:ok, 2}, else: braced_hex(rest)
  end

  defp hex(rest), do: braced_hex(rest)

  @spec braced_hex([binary()]) :: {:ok, pos_integer()} | :error
  defp braced_hex(["{" | rest]) do
    {digits, tail} = Enum.split_while(rest, &(&1 != "}"))

    with ["}" | _more] <- tail,
         true <- digits != [] and length(digits) <= 6 and hex_digits?(digits),
         value = digits |> Enum.join() |> String.to_integer(16),
         true <- value <= 0x10FFFF and value not in 0xD800..0xDFFF do
      {:ok, length(digits) + 2}
    else
      _no_character -> :error
    end
  end

  defp braced_hex(_other), do: :error

  @spec hex_digits?([binary()]) :: boolean()
  defp hex_digits?(digits), do: Enum.all?(digits, &String.match?(&1, ~r/\A[0-9a-fA-F]\z/))

  # `\p{Name}` or `\pL`: the property exists when it is a general category, which PCRE and the
  # crate read alike.
  @spec unicode(binary(), [binary()], non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:unknown, binary()} | error()
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
        property(kind, name, at, Enum.count(name) + 2, @categories)
    end
  end

  defp unicode(kind, [letter | _rest], at, _length),
    do: property(kind, [letter], at, 1, @single)

  @spec property(binary(), [binary()], non_neg_integer(), pos_integer(), [binary()]) ::
          {:ok, pos_integer()} | {:unknown, binary()} | error()
  defp property(_kind, name, at, taken, known) do
    text = Enum.join(name)

    cond do
      text in known -> {:ok, taken}
      text in @refused -> {:error, at, at + 2 + taken, missing(text)}
      true -> {:unknown, @property}
    end
  end

  # `\p{Script=Foo}` names a property that exists and a value that does not.
  @spec missing(binary()) :: binary()
  defp missing("Script=Foo"), do: "Unicode property value not found"
  defp missing(_name), do: "Unicode property not found"

  # ---------------------------------------------------------------------------
  # Character classes
  # ---------------------------------------------------------------------------

  # The class after a `[` that stood at `at`, read to its end.
  @spec class([binary()], non_neg_integer(), non_neg_integer(), [non_neg_integer()]) ::
          verdict()
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
          {:ok, non_neg_integer()} | :unclosed | {:unknown, binary()} | error()
  defp class_items(chars, at), do: class_items(chars, at, 0)

  defp class_items([], _at, _taken), do: :unclosed
  defp class_items(["]" | _rest], _at, taken), do: {:ok, taken + 1}
  defp class_items(["[" | _rest], _at, _taken), do: {:unknown, @nested_class}

  defp class_items([operator, operator | _rest], _at, _taken) when operator in ["&", "-", "~"],
    do: {:unknown, @class_operator}

  defp class_items(["\\", <<letter>>, "-", high | _rest], at, _taken)
       when letter in ~c"dDwWsS" and high != "]",
       do: {:error, at, at + 2, "invalid range boundary, must be a literal"}

  defp class_items([low, "-", "\\", <<letter>> | _rest], at, _taken)
       when low != "\\" and letter in ~c"dDwWsS",
       do: {:error, at + 2, at + 4, "invalid range boundary, must be a literal"}

  defp class_items(["\\", <<letter>> | rest], at, taken) when letter in @class_escapes,
    do: class_items(rest, at + 2, taken + 2)

  defp class_items(["\\", "x", high, low | rest], at, taken) do
    if hex_digits?([high, low]),
      do: class_items(rest, at + 4, taken + 4),
      else: {:unknown, @class_escape}
  end

  defp class_items(["\\", <<digit>> | _rest], at, _taken) when digit in ?0..?9,
    do: {:error, at, at + 2, "backreferences are not supported"}

  defp class_items(["\\", <<letter>> | _rest], at, _taken)
       when letter in ?a..?z or letter in ?A..?Z do
    if letter in ~c"bBAzxuUpPQEG",
      do: {:unknown, @class_escape},
      else: {:error, at, at + 2, "unrecognized escape sequence"}
  end

  defp class_items(["\\", _punctuation | rest], at, taken),
    do: class_items(rest, at + 2, taken + 2)

  defp class_items(["\\"], at, _taken),
    do: {:error, at, at + 1, "incomplete escape sequence, reached end of pattern prematurely"}

  defp class_items([_low, operator, operator | _rest], _at, _taken)
       when operator in ["&", "-", "~"],
       do: {:unknown, @class_operator}

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
