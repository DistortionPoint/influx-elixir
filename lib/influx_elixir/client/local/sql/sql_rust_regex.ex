defmodule InfluxElixir.Client.Local.SQLRustRegex do
  @moduledoc false
  # The error the engine's regular expression crate gives a pattern it cannot compile, and what
  # the double knows of the patterns it does compile, for the `~` operators of
  # `InfluxElixir.Client.Local` (verified against InfluxDB 3 Core, each message below on a
  # pattern of its own).
  #
  # The double matches with PCRE, whose syntax is not the crate's: PCRE accepts look-around,
  # back references and `\Z`, which the crate refuses, words its own errors differently, and
  # reads constructs the crate reads another way (`[a&&b]`, `\b{start}`, `\p{Greek}`, which is
  # the script extensions in PCRE; `\v`, which is any vertical whitespace in PCRE and the
  # vertical tab alone in the crate; `a++`, which is possessive in PCRE and a repeated repeat in
  # the crate). The engine's error names the pattern and the place of the fault:
  #
  #     regex parse error:
  #         a{2,1}
  #          ^^^^^
  #     error: invalid repetition count range, the start must be <= the end
  #
  # This reads a pattern left to right as the crate's parser does, and stops at the first
  # fault it knows the words of. A pattern it reads to the end is `:ok`, and PCRE's match is
  # the engine's (but see `guard/1`, for a text where it is not). A pattern that holds a
  # construct it does not read is `{:unknown, cause}`, which the caller refuses by name,
  # whatever PCRE says of it: the double does not know what the crate does with it. What it
  # reads is:
  #
  #   * groups: `(...)`, `(?:...)` and the flag groups `(?i)`, `(?s)`, `(?m)`, `(?i:...)`,
  #     `(?s:...)` and `(?m:...)`; every other `(?` is not read
  #   * escapes: the letters of `@escapes`, `\x` with exactly two hex digits or `{hex}`, an ASCII
  #     punctuation mark (a character that is not ASCII is the crate's error), and `\p` / `\P` of
  #     a general category (`@categories`); not `\v`, `\b{...}`, `\u`, `\U`, the name of a script
  #     (PCRE reads the script extensions, the crate the script) or any other name: the
  #     crate's error for a property it does not have is not known for every name
  #   * classes: a literal, a range, `\d` and its kin, `\x` of two hex digits; not a nested
  #     class (`[[:alpha:]]`, which is ASCII to the crate) or an operator (`&&`, `--`, `~~`)
  #   * a brace after something to repeat that is a count (`a{2,3}`) or a fault the crate
  #     words, as the crate reads the count: optional white space around each number is part of
  #     it (`a{ 1, 2 }`), which PCRE does not read, so a count with white space is not read; a
  #     brace with nothing before it is the crate's error
  #   * a quantifier followed by `+` is not read (possessive to PCRE)
  #   * a pattern of several lines, or one that may be too large for the crate to compile (see
  #     `size/1`), is not read

  @escapes ~c"dDwWsSbBAzntrfa"
  @class_escapes ~c"dDwWsSntrfa"

  # The general categories PCRE and the crate read alike. Not `C`, `Cn` or `Cs` (their members
  # depend on the version of Unicode, and the crate has no `Cs`), not the scripts, the long names
  # (`Letter`), `gc=L` or `IsLatin`, which PCRE does not read.
  @categories ~w(L Lu Ll Lt Lm Lo M Mn Mc Me N Nd Nl No P Pc Pd Ps Pe Pi Pf Po S Sm Sc Sk So
    Z Zs Zl Zp Cc Cf Co)
  @single ~w(L M N P S Z)

  # The largest count of a repetition (`u32`), and the cost the double lets a pattern have (see
  # `size/1`).
  @max_count 4_294_967_295
  @max_cost 250_000

  @several_lines "a pattern of several lines"
  @group "a group other than (?:...) and the flag groups (?i) (?s) (?m)"
  @flag_repeat "a repetition operator after a flag group"
  @escape "an escape the double does not read (\\u, \\U, \\x without two hex digits, \\b{...})"
  @vertical "a \\v escape (any vertical whitespace to PCRE, the vertical tab alone to the crate)"
  @class_escape "an escape in a character class the double does not read"
  @nested_class "a nested character class"
  @class_dashes "two or more hyphens that open a character class (characters to the crate)"
  @class_operator "a character class operator (&&, -- or ~~)"
  @property "a Unicode property the double has not verified"
  @possessive "a quantifier followed by + (possessive to PCRE, a repeated repeat to the crate)"
  @spaced "white space inside a counted repetition (PCRE reads it as text)"
  @too_big "a repetition so large that the crate may refuse to compile the pattern"

  @unclosed "unclosed counted repetition"
  @decimal_empty "repetition quantifier expects a valid decimal"
  @missing "repetition operator missing expression"

  @typep error :: {:error, non_neg_integer(), non_neg_integer(), binary()}
  @typep verdict :: :ok | {:unknown, binary()} | :differs | error()

  @typedoc """
  What the crate does with a pattern: compiles it (`:ok`), compiles it as PCRE does not read it
  (`:differs`), refuses it with the text `{:error, text}`, or the double does not know
  (`{:unknown, cause}`).
  """
  @type result :: :ok | :differs | {:unknown, binary()} | {:error, binary()}

  @typedoc """
  What a compiled pattern can tell about a text without running it: whether a text with a newline
  (`:newline`) or with a character that is not ASCII (`:unicode`) is read another way by PCRE
  and the crate.
  """
  @type guard :: %{newline: boolean(), unicode: boolean()}

  @doc """
  The engine's error text for the pattern, `:ok` for a pattern it compiles, `:differs` for one
  PCRE reads another way, else `{:unknown, cause}`.
  """
  @spec check(binary()) :: result()
  def check(pattern) do
    if String.contains?(pattern, ["\n", "\r"]) do
      {:unknown, @several_lines}
    else
      chars = String.codepoints(pattern)

      case scan(chars, 0, length(chars), [], false) do
        {:error, start, stop, message} -> {:error, format(pattern, start, stop, message)}
        :ok -> size(chars)
        verdict -> verdict
      end
    end
  end

  @doc """
  What of a pattern PCRE and the crate read differently for some texts, found once when the
  pattern is compiled (not for every row). For a text with a newline: `$`, `\\z` and the `(?m`
  flag, whose ends and starts of lines are not alike; for a text that is not ASCII: `\\w`, `\\d`,
  `\\s`, `\\b` (other sets of characters in the crate) and a case-insensitive match (other
  folding).
  """
  @spec guard(Regex.t()) :: guard()
  def guard(%Regex{source: source} = regex) do
    %{
      newline: String.contains?(source, ["$", "\\z", "(?m"]),
      unicode:
        :caseless in Regex.opts(regex) or
          String.contains?(source, ["\\w", "\\W", "\\d", "\\D", "\\s", "\\S", "\\b", "\\B", "(?i"])
    }
  end

  @doc """
  Whether the double declines to match the text: it is one the pattern's `guard/1` says the two
  read differently. This depends on the data, not on the query alone: one row with a newline
  or a character that is not ASCII refuses a query that was answered before it was written.
  """
  @spec differs?(guard(), binary()) :: boolean()
  def differs?(%{newline: false, unicode: false}, _text), do: false
  def differs?(%{newline: true, unicode: false}, text), do: newline?(text)

  def differs?(%{newline: false, unicode: true}, text),
    do: not newline?(text) and not ascii?(text)

  def differs?(%{newline: true, unicode: true}, text),
    do: newline?(text) or not ascii?(text)

  @spec newline?(binary()) :: boolean()
  defp newline?(text), do: :binary.match(text, "\n") != :nomatch

  @spec ascii?(binary()) :: boolean()
  defp ascii?(<<byte, rest::binary>>) when byte < 128, do: ascii?(rest)
  defp ascii?(<<>>), do: true
  defp ascii?(_text), do: false

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
    do: {:error, at, at + 1, @missing}

  # A quantifier followed by `+` is possessive to PCRE and a repeat of a repeat to the crate.
  defp scan([operator, "+" | _rest], _at, _length, _groups, true)
       when operator in ["*", "+", "?"],
       do: {:unknown, @possessive}

  defp scan([operator | rest], at, length, groups, true) when operator in ["*", "+", "?"],
    do: scan(rest, at + 1, length, groups, true)

  # A brace with nothing before it is the crate's error whatever follows it.
  defp scan(["{" | _rest], at, _length, _groups, false), do: {:error, at, at + 1, @missing}

  defp scan(["{" | rest], at, length, groups, true) do
    case counted(rest, at) do
      {:ok, taken, low, high, spaced?} ->
        after_count = Enum.drop(rest, taken - 1)

        cond do
          high != nil and high < low -> invalid_range(at, taken)
          spaced? -> {:unknown, @spaced}
          match?(["+" | _more], after_count) -> {:unknown, @possessive}
          true -> scan(after_count, at + taken, length, groups, true)
        end

      {:error, _start, _stop, _message} = error ->
        error
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

  # The `{n}`, `{n,}` or `{n,m}` after the opening brace at `at`, read as the crate reads it:
  # white space may stand around a number (and nowhere else, so `{1, }` is a missing number),
  # and the error points where the crate's parser stopped. The result is how many characters
  # the count takes with both braces, its bounds and whether it held white space.
  @spec counted([binary()], non_neg_integer()) ::
          {:ok, pos_integer(), non_neg_integer(), non_neg_integer() | nil, boolean()} | error()
  defp counted([], at), do: {:error, at, at + 1, @unclosed}

  defp counted(chars, at) do
    with {:ok, low, rest, pos} <- decimal(chars, at + 1),
         {:ok, high, rest, pos} <- upper_bound(rest, pos, at, low),
         :ok <- closed(rest, pos, at) do
      taken = pos - at + 1
      {:ok, taken, low, high, Enum.any?(Enum.take(chars, taken - 2), &white_space?/1)}
    end
  end

  # After the first number: a comma and the second number (or none), or the closing brace.
  @spec upper_bound([binary()], non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer() | nil, [binary()], non_neg_integer()} | error()
  defp upper_bound([], pos, at, _low), do: {:error, at, pos, @unclosed}

  defp upper_bound(["," | rest], pos, at, _low) do
    case rest do
      [] -> {:error, at, pos + 1, @unclosed}
      ["}" | _more] -> {:ok, nil, rest, pos + 1}
      _number -> decimal(rest, pos + 1)
    end
  end

  defp upper_bound(rest, pos, _at, low), do: {:ok, low, rest, pos}

  @spec closed([binary()], non_neg_integer(), non_neg_integer()) :: :ok | error()
  defp closed(["}" | _rest], _pos, _at), do: :ok
  defp closed(_rest, pos, at), do: {:error, at, pos, @unclosed}

  # A number of a count: white space, digits (a `u32`), white space.
  @spec decimal([binary()], non_neg_integer()) ::
          {:ok, non_neg_integer(), [binary()], non_neg_integer()} | error()
  defp decimal(rest, pos) do
    {rest, start} = skip_space(rest, pos)
    {digits, rest} = Enum.split_while(rest, &(&1 in ~w(0 1 2 3 4 5 6 7 8 9)))
    stop = start + length(digits)

    cond do
      digits == [] ->
        {:error, stop, stop + 1, @decimal_empty}

      String.to_integer(Enum.join(digits)) > @max_count ->
        {:error, start, stop, "decimal literal invalid"}

      true ->
        {rest, pos} = skip_space(rest, stop)
        {:ok, String.to_integer(Enum.join(digits)), rest, pos}
    end
  end

  # The characters the crate takes for white space (Unicode `White_Space`).
  @white_space [
    "\t",
    "\n",
    "\v",
    "\f",
    "\r",
    " ",
    <<0x85::utf8>>,
    <<0xA0::utf8>>,
    <<0x1680::utf8>>,
    <<0x2028::utf8>>,
    <<0x2029::utf8>>,
    <<0x202F::utf8>>,
    <<0x205F::utf8>>,
    <<0x3000::utf8>>
  ]

  @spec skip_space([binary()], non_neg_integer()) :: {[binary()], non_neg_integer()}
  defp skip_space(chars, pos) do
    {spaces, rest} = Enum.split_while(chars, &white_space?/1)
    {rest, pos + length(spaces)}
  end

  @spec white_space?(binary()) :: boolean()
  defp white_space?(char) when char in @white_space, do: true

  defp white_space?(<<code::utf8>>) when code in 0x2000..0x200A, do: true
  defp white_space?(_char), do: false

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

  defp escape(["v" | _rest], _at, _length, _groups), do: {:unknown, @vertical}

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

  # The crate escapes ASCII punctuation (and space and controls) and nothing else.
  defp escape([char | _rest], at, _length, _groups) when byte_size(char) > 1,
    do: {:error, at, at + 2, "unrecognized escape sequence"}

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
  defp property(_kind, name, _at, taken, known) do
    if Enum.join(name) in known, do: {:ok, taken}, else: {:unknown, @property}
  end

  # ---------------------------------------------------------------------------
  # Character classes
  # ---------------------------------------------------------------------------

  # The class after a `[` that stood at `at`, read to its end. The crate takes the hyphens that
  # open a class as characters (so `[--a]` is not the range of PCRE), and a `]` that comes first
  # (no hyphen before it) as a character too; its error for a class that does not end points at
  # what it took (`[^]`, `[-`, but only the `[` when the text ends in the hyphens).
  @spec class([binary()], non_neg_integer(), non_neg_integer(), [non_neg_integer()]) ::
          verdict()
  defp class(rest, at, length, groups) do
    {negated, body} = if match?(["^" | _more], rest), do: {1, tl(rest)}, else: {0, rest}
    {dashes, body} = Enum.split_while(body, &(&1 == "-"))

    {bracket, body} =
      case {dashes, body} do
        {[], ["]" | more]} -> {1, more}
        _other -> {0, body}
      end

    opened = at + 1 + negated + length(dashes) + bracket

    case class_items(body, opened) do
      {:ok, _taken} when length(dashes) >= 2 ->
        {:unknown, @class_dashes}

      {:ok, taken} ->
        scan(Enum.drop(body, taken), opened + taken, length, groups, true)

      :unclosed ->
        width = if dashes != [] and body == [], do: 1, else: opened - at
        {:error, at, at + width, "unclosed character class"}

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

  defp class_items(["\\", "v" | _rest], _at, _taken), do: {:unknown, @vertical}

  # The crate escapes ASCII punctuation (and space and controls) and nothing else.
  defp class_items(["\\", char | _rest], at, _taken) when byte_size(char) > 1,
    do: {:error, at, at + 2, "unrecognized escape sequence"}

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

  # `\<` and `\>` are word boundaries outside a class; what the crate does with them inside one
  # depends on what follows them (an invalid escape, or the class that does not end), which the
  # double does not follow.
  defp class_items(["\\", angle | _rest], _at, _taken) when angle in ["<", ">"],
    do: {:unknown, @class_escape}

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

  # ---------------------------------------------------------------------------
  # Size
  # ---------------------------------------------------------------------------

  # The crate compiles a repetition by copying what it repeats, and gives up on a pattern whose
  # copies exceed its limit: on Core `(a{1000}){1000}`, `\w{1000}` and `(.{1000}){100}` close the
  # connection instead of answering (verified), and PCRE answers them. A pattern is costed (a
  # character 1, `.` and a negated class 20, a class 4, `\w`, `\d`, `\s`, `\pL` and their kin
  # 1200, a group the sum of what it holds, a repetition the product of its count and the cost
  # of what it repeats) and one above `@max_cost` is not read. The weights are fitted to what
  # Core did, not the crate's: every pattern probed that it answered costs less than the
  # bound or at it (`(a{500}){500}` 250,000; `\w{200}` and `\pL{200}` 240,000;
  # `(.{100}){100}` 200,000; `[a-z]{10000}`), and every one it closed the connection on costs
  # more (`(a{600}){600}` 360,000; `(a{300}){1000}` 300,000; `\w{300}` and `\pL{300}` 360,000;
  # `(.{200}){100}` 400,000; `(\pL{50}){10}` 600,000; `(\w{20}){20}` 480,000). Between the two
  # the bound is a guess, and what is above it is refused, not answered.
  @spec size([binary()]) :: :ok | {:unknown, binary()}
  defp size(chars) do
    {cost, _rest} = sequence(chars, 0)
    if cost > @max_cost, do: {:unknown, @too_big}, else: :ok
  end

  # The cost of what stands up to a `)` (not taken) or the end; alternatives add up.
  @spec sequence([binary()], non_neg_integer()) :: {non_neg_integer(), [binary()]}
  defp sequence([], cost), do: {cost, []}
  defp sequence([")" | _rest] = rest, cost), do: {cost, rest}

  defp sequence(chars, cost) do
    {unit, rest} = atom(chars)
    {times, rest} = repeats(rest, 1)
    sequence(rest, cost + unit * times)
  end

  @spec atom([binary()]) :: {non_neg_integer(), [binary()]}
  defp atom(["|" | rest]), do: {0, rest}
  defp atom(["." | rest]), do: {20, rest}

  defp atom(["\\", property, "{" | rest]) when property in ["p", "P"],
    do: {1200, rest |> Enum.drop_while(&(&1 != "}")) |> Enum.drop(1)}

  defp atom(["\\", property, _letter | rest]) when property in ["p", "P"], do: {1200, rest}
  defp atom(["\\", escape | rest]) when escape in ~w(d D w W s S), do: {1200, rest}
  defp atom(["\\", _escape | rest]), do: {1, rest}

  defp atom(["(", "?", flag, ")" | rest]) when flag in ["i", "s", "m"], do: {0, rest}

  defp atom(["(" | rest]) do
    opening =
      case rest do
        ["?", ":" | _more] -> 2
        ["?", _flag, ":" | _more] -> 3
        _plain -> 0
      end

    {cost, [")" | rest]} = rest |> Enum.drop(opening) |> sequence(0)
    {cost, rest}
  end

  defp atom(["[" | rest]), do: class_cost(rest)
  defp atom([_char | rest]), do: {1, rest}

  # A class is read to its `]`, as `class/4` read it; one with `\w` or `\p` in it costs as they.
  @spec class_cost([binary()]) :: {non_neg_integer(), [binary()]}
  defp class_cost(rest) do
    {base, rest} = if match?(["^" | _more], rest), do: {20, tl(rest)}, else: {4, rest}
    {dashes, rest} = Enum.split_while(rest, &(&1 == "-"))
    rest = if dashes == [] and match?(["]" | _more], rest), do: tl(rest), else: rest
    class_end(rest, base)
  end

  @spec class_end([binary()], non_neg_integer()) :: {non_neg_integer(), [binary()]}
  defp class_end(["]" | rest], cost), do: {cost, rest}

  defp class_end(["\\", escape | rest], _cost) when escape in ~w(p P d D w W s S),
    do: class_end(rest, 1200)

  defp class_end(["\\", _escape | rest], cost), do: class_end(rest, cost)
  defp class_end([_char | rest], cost), do: class_end(rest, cost)
  defp class_end([], cost), do: {cost, []}

  # The quantifiers after an atom, multiplied: `*`, `+` and `?` repeat once more at most, a
  # count by its largest number (one more for `{n,}`).
  @spec repeats([binary()], non_neg_integer()) :: {non_neg_integer(), [binary()]}
  defp repeats([operator | rest], times) when operator in ["*", "+", "?"],
    do: repeats(rest, times)

  defp repeats(["{" | rest], times) do
    {inner, tail} = Enum.split_while(rest, &(&1 != "}"))

    count =
      case inner |> Enum.join() |> String.split(",") |> Enum.map(&String.trim/1) do
        [low] -> String.to_integer(low)
        [low, ""] -> String.to_integer(low) + 1
        [_low, high] -> String.to_integer(high)
      end

    repeats(Enum.drop(tail, 1), times * max(count, 1))
  end

  defp repeats(rest, times), do: {times, rest}
end
