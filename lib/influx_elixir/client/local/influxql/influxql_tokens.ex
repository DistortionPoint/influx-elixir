defmodule InfluxElixir.Client.Local.InfluxQLTokens do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
  # The tokens of an InfluxQL `WHERE`, read as the engine's parser reads them:
  # strings, quoted identifiers, regular expressions, numbers, durations,
  # operators and words. What the parser cannot read comes back as
  # `{:syntax_error, kind, rest}` with the text left from the error, which
  # `InfluxElixir.Client.Local.InfluxQLCheck` turns into the engine's body.

  alias InfluxElixir.Client.Local.{
    Durations,
    InfluxQLLex,
    InfluxQLText,
    SQLIdentifiers,
    SQLLimits
  }

  require InfluxQLLex
  require SQLLimits

  @doc false
  @spec time?(term()) :: boolean()
  def time?({:ident, name}), do: String.downcase(name) == "time"
  def time?(_token), do: false

  @spec tokenize(binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  @doc false
  def tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  # A `.` that stands after an operand and a blank is where the condition ends (a dotted name
  # has no blank in it; verified: `x .y`, `3 .`, `(3) .`, `'a' .`, `true .`, `now() .`).
  def tokenize(<<c, rest::binary>>, [previous | _before] = acc) when InfluxQLLex.is_blank(c) do
    trimmed = InfluxQLLex.trim_blanks(rest)

    if String.starts_with?(trimmed, ".") and operand_end?(previous),
      do: {:syntax_error, :nom, trimmed},
      else: tokenize(rest, acc)
  end

  def tokenize(<<c, rest::binary>>, acc) when InfluxQLLex.is_blank(c), do: tokenize(rest, acc)

  # A token that follows an operand with no operator between them is where the engine's
  # parser stops: the condition ended before it.
  def tokenize(text, [previous | _before] = acc) do
    if leftover_token?(previous, text),
      do: {:syntax_error, :nom, text},
      else: lex(text, acc)
  end

  # A condition that starts with what can start no operand (after any parentheses and signs)
  # is not read at all: the statement is left from its `WHERE` (verified: `WHERE = 1`,
  # `WHERE != 1 AND n`, `WHERE ) 1`, `WHERE ((>= 1))`, `WHERE -* n`).
  def tokenize(text, []) do
    if InfluxQLLex.operand_missing?(text),
      do: {:syntax_error, :where_unparsed, text},
      else: lex(text, [])
  end

  @spec lex(binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp lex(<<?', rest::binary>>, acc) do
    {content, rest} = take_until(rest, ?', [])
    # InfluxQL escapes a quote with a backslash, SQL by doubling it.
    operand_token({:str, String.replace(content, "\\'", "''")}, rest, acc)
  end

  defp lex(<<?", rest::binary>>, acc) do
    {name, rest} = take_until(rest, ?", [])
    operand_token({:ident, String.replace(name, "\\\"", "\"")}, rest, acc)
  end

  # A bind parameter is an operand like a name (verified: what follows it is left over as it is
  # after a name, `$a.b` and `$a::tag` from the dot and the colons). The double binds none.
  defp lex(<<?$, _rest::binary>> = text, acc) do
    case InfluxQLLex.take_param(text) do
      {_param, <<?., _more::binary>> = rest} -> {:syntax_error, :nom, rest}
      {_param, <<"::", _more::binary>> = rest} -> {:syntax_error, :nom, rest}
      {param, rest} -> tokenize(rest, [{:param, param} | acc])
      nil -> {:error, "unsupported InfluxQL WHERE: " <> text}
    end
  end

  defp lex(<<?/, _rest::binary>> = text, []), do: {:syntax_error, :where_unparsed, text}

  defp lex(<<?/, rest::binary>>, [{:op, op} | _tokens] = acc) when op in ["=~", "!~"] do
    {pattern, rest} = take_regex(rest, [])

    if SQLIdentifiers.word_next?(rest) and not connective?(rest),
      do: {:syntax_error, :nom, rest},
      else: tokenize(rest, [{:regex, pattern} | acc])
  end

  defp lex(<<op::binary-size(2), rest::binary>>, acc)
       when op in ["=~", "!~", "!=", "<>", "<=", ">="],
       do: operand(rest, {:op, op}, acc)

  defp lex(<<c, rest::binary>>, acc) when c in [?=, ?<, ?>],
    do: operand(rest, {:op, <<c>>}, acc)

  # A binary `+` or `-` fails where its operand should start when nothing that can start one
  # stands there (verified: `(f +)`, `f + = 1`, `f > 1 + )` fail at the `)` or the operator).
  defp lex(<<c, rest::binary>> = text, [previous | _before] = acc) when c in [?+, ?-] do
    cond do
      not operand_end?(previous) ->
        tokenize(rest, [{:raw, <<c>>} | acc])

      InfluxQLLex.operand_missing?(rest) ->
        {:syntax_error, :reserved_failure, InfluxQLLex.trim_blanks(rest)}

      InfluxQLLex.trim_both_blanks(rest) != "" ->
        tokenize(rest, [{:raw, <<c>>} | acc])

      # A sign that ends the text fails the same way; after a `)` it is left over from a
      # closed condition (`(f) +`) and fails inside an open group (`((f) +`), which the double
      # does not tell apart from a call or an expression in parentheses.
      previous == {:raw, ")"} ->
        {:error, "unsupported InfluxQL WHERE: " <> text}

      true ->
        {:syntax_error, :reserved_failure, InfluxQLLex.trim_blanks(rest)}
    end
  end

  # A `*` or `/` that no operand follows is left over from itself (verified: `f * AND n`,
  # `f > 1 AND f *`); inside parentheses the whole parenthesised condition fails, which the
  # double does not place.
  defp lex(<<c, rest::binary>> = text, [previous | _before] = acc) when c in [?*, ?/] do
    cond do
      not (operand_end?(previous) and
               (InfluxQLLex.operand_missing?(rest) or
                  InfluxQLLex.trim_both_blanks(rest) == "")) ->
        tokenize(rest, [{:raw, <<c>>} | acc])

      open_parens(acc) == 0 ->
        {:syntax_error, :nom, text}

      true ->
        {:error, "unsupported InfluxQL WHERE: " <> text}
    end
  end

  # A `,` outside every parenthesis ends the condition: what follows is left over from it.
  defp lex(<<?,, rest::binary>> = text, [previous | _before] = acc) do
    if operand_end?(previous) and open_parens(acc) == 0,
      do: {:syntax_error, :nom, text},
      else: tokenize(rest, [{:raw, ","} | acc])
  end

  # A `(` after a number or a string is no call: it is left over (unless an earlier `)` closed
  # nothing, which ends the condition first).
  defp lex(<<?(, _rest::binary>> = text, [{kind, _value} | _before] = acc)
       when kind in [:number, :str] do
    if open_parens(acc) >= 0,
      do: {:syntax_error, :nom, text},
      else: tokenize(binary_part(text, 1, byte_size(text) - 1), [{:raw, "("} | acc])
  end

  defp lex(<<c, rest::binary>>, acc) when c in [?(, ?), ?+, ?-, ?*, ?/, ?,],
    do: tokenize(rest, [{:raw, <<c>>} | acc])

  # A number, a duration, `now()` or a word, read from the start of the text (not a Unicode
  # pattern: it would check the whole text for UTF-8 at every token).
  @lexeme Regex.compile!(
            "^(?:((?:\\d+(?:ns|ms|u|µ|s|m|h|d|w))+)|(\\d*\\.\\d+|\\d+)|" <>
              InfluxElixir.Client.Local.InfluxQLBlankRegex.blank_pattern(
                "((?i:now)\\s*\\(\\s*\\))|([A-Za-z_]\\w*))"
              )
          )

  defp lex(text, acc) do
    case Regex.run(@lexeme, text) do
      [full, duration] ->
        duration_token(duration, rest_after(text, full), acc)

      [full, "", number] ->
        number_token(number, rest_after(text, full), acc)

      [full, "", "", _now] ->
        tokenize(rest_after(text, full), [{:raw, "now()"} | acc])

      [full, "", "", "", word] ->
        word_token(String.upcase(word), word, rest_after(text, full), acc)

      nil ->
        {:error, "unsupported InfluxQL WHERE: #{text}"}
    end
  end

  # A duration is one or more `<count><unit>` parts (`1h30m`), added up. A
  # count beyond 64 bits is the engine's overflow, one beyond the signed range
  # an integer that its unit is left over from, and a total beyond the signed
  # range an overflow after the whole duration. Whatever follows the duration
  # and is no blank, operator or parenthesis is left over from there.
  @spec duration_token(binary(), binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp duration_token(text, rest, acc) do
    case duration_total(text, rest, 0) do
      {:ok, total} when total > SQLLimits.int64_max() -> {:syntax_error, :duration_overflow, rest}
      {:ok, total} -> duration_end(total, text, rest, acc)
      {:error, kind, at} -> {:syntax_error, kind, at}
    end
  end

  defp duration_end(total, text, rest, acc) do
    if leftover?(rest),
      do: {:syntax_error, :nom, rest},
      else: tokenize(rest, [{:duration, total, text} | acc])
  end

  @spec duration_total(binary(), binary(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom(), binary()}
  defp duration_total(<<>>, _rest, total), do: {:ok, total}

  defp duration_total(text, rest, total) do
    [part, n, unit] = Regex.run(~q/^(\d+)(ns|ms|u|µ|s|m|h|d|w)/, text)
    count = String.to_integer(n)
    after_count = binary_part(text, byte_size(n), byte_size(text) - byte_size(n)) <> rest
    after_part = binary_part(text, byte_size(part), byte_size(text) - byte_size(part))

    cond do
      count > SQLLimits.uint64_max() -> {:error, :overflow, after_count}
      count > SQLLimits.int64_max() -> {:error, :nom, after_count}
      true -> duration_total(after_part, rest, total + count * Durations.ns(unit))
    end
  end

  # A letter, digit or underscore next (`SQLIdentifiers.word_next?/1`) after a regular
  # expression (`/re/i`) is a flag the engine has none for: it is left over.
  @spec leftover?(binary()) :: boolean()
  defp leftover?(rest), do: SQLIdentifiers.word_next?(rest) or String.starts_with?(rest, ".")

  # A number that a letter, digit, underscore or dot follows is cut short
  # there, which the engine cannot continue from.
  @spec number_token(binary(), binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp number_token(number, rest, acc) do
    if leftover?(rest) and not InfluxQLLex.spaced_connective?(rest) do
      {:syntax_error, :nom, rest}
    else
      case integer_overflow(number, acc) do
        nil -> tokenize(rest, [{:number, number} | acc])
        kind -> {:syntax_error, kind, rest}
      end
    end
  end

  # Whether `text`, where the next token starts, cannot follow the token `previous`: an operand
  # beside an operand, or after a regular expression (which ends its comparison) anything but
  # a connective or a closing parenthesis. A comparison operator is left to the clause that
  # reads it.
  # The characters no token starts with, and `!` but for `!=` and `!~`.
  @stray "[#@$?}\\][\\\\`{~\\x80-\\xFF]|!(?![=~])"
  @after_regex Regex.compile!("^(?:[\\d.'\"+\\-*\\/,(]|[A-Za-z_]|" <> @stray <> ")")
  @after_operand Regex.compile!("^(?:['\"\\d]|\\.\\d|[A-Za-z_]|" <> @stray <> ")")

  @spec leftover_token?(term(), binary()) :: boolean()
  defp leftover_token?({:regex, _pattern}, text),
    do: Regex.match?(@after_regex, text) and not connective?(text)

  # A parenthesis after `now()` or a boolean is left over: neither names a call.
  defp leftover_token?({:raw, word}, <<?(, _rest::binary>>) when is_binary(word),
    do: String.upcase(word) in ["NOW()", "TRUE", "FALSE"]

  defp leftover_token?(previous, text),
    do: operand_end?(previous) and Regex.match?(@after_operand, text) and not connective?(text)

  @spec operand_end?(term()) :: boolean()
  defp operand_end?({kind, _value}) when kind in [:ident, :number, :str, :param], do: true
  defp operand_end?({:duration, _total, _text}), do: true
  defp operand_end?({:raw, word}), do: String.upcase(word) in ["TRUE", "FALSE", "NOW()", ")"]
  defp operand_end?(_token), do: false

  @spec connective?(binary()) :: boolean()
  defp connective?(text), do: Regex.match?(~q/^(?:AND|OR)(?![\w])/i, text)

  # An integer literal fits the unsigned 64-bit range, a negated one the
  # signed range; a number with a fraction has no range.
  @spec integer_overflow(binary(), list()) :: :overflow | :signed_overflow | nil
  defp integer_overflow(number, acc) do
    case Integer.parse(number) do
      {n, ""} when n > SQLLimits.uint64_max() -> :overflow
      {n, ""} when n > SQLLimits.int64_max() + 1 -> if negated?(acc), do: :signed_overflow
      _fits_or_fraction -> nil
    end
  end

  # A minus is a sign, not a subtraction, at the start, after a comparison,
  # an opening parenthesis, a connective or another operator.
  @spec negated?(list()) :: boolean()
  defp negated?([{:raw, "-"} | before]) do
    case before do
      [] -> true
      [{:op, _op} | _more] -> true
      [{:raw, word} | _more] -> String.upcase(word) in ["(", "AND", "OR", "+", "-", "*", "/"]
      _operand -> false
    end
  end

  defp negated?(_acc), do: false

  # `NOT` is no keyword but a name like any other; a word, number or quoted
  # text after it (other than a connective) is left over, where it starts.
  # `AND` or `OR` with nothing after it has no operand.
  @spec word_token(binary(), binary(), binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp word_token("NOT", word, rest, acc) do
    if Regex.match?(~q/^\s*(?!(?:AND|OR)\b)[A-Za-z_0-9."']/i, rest),
      do: {:syntax_error, :nom, InfluxQLLex.trim_blanks(rest)},
      else: tokenize(rest, [{:ident, word} | acc])
  end

  # `AND` or `OR` where an operand is wanted is a name when a quote, a glued character or a
  # carriage return stands directly against it (it is no connective there: verified at the
  # start of the condition, after a comparison, a sign and a connective): the name is an
  # operand and what follows it is left over as after any operand. Inside parentheses the
  # whole group fails, which the double places at the `WHERE`.
  defp word_token(upcased, word, rest, acc) when upcased in ["AND", "OR"] do
    cond do
      name_position?(acc, rest) -> operand_token({:ident, word}, rest, acc)
      reserved_kind(acc) != :nom -> {:syntax_error, reserved_kind(acc), word <> rest}
      InfluxQLLex.cr_after?(rest, 0) -> {:syntax_error, :nom, word <> rest}
      InfluxQLLex.glued?(rest) -> {:syntax_error, :nom, word <> rest}
      InfluxQLLex.trim_both_blanks(rest) == "" -> {:syntax_error, :operand, rest}
      InfluxQLLex.operand_missing?(rest) -> {:syntax_error, :operand, rest}
      Regex.match?(~q/\A['".]/, rest) -> {:syntax_error, :nom, word <> rest}
      String.starts_with?(InfluxQLLex.trim_blanks(rest), "/") -> {:syntax_error, :operand, rest}
      true -> tokenize(rest, [{:raw, word} | acc])
    end
  end

  defp word_token(upcased, word, rest, acc) do
    if InfluxQLText.reserved?(word) and not String.starts_with?(rest, ":"),
      do: {:syntax_error, reserved_kind(acc), word <> rest},
      else: operand_token(plain_word(upcased, word), rest, acc)
  end

  @spec name_position?(list(), binary()) :: boolean()
  defp name_position?(acc, rest) do
    reserved_kind(acc) != :nom and open_parens(acc) == 0 and
      (InfluxQLLex.cr_after?(rest, 0) or InfluxQLLex.glued?(rest) or
         Regex.match?(~q/\A['"]/, rest))
  end

  # A minus sign takes a number, a name, a call or a parenthesis; before a string or a
  # boolean, or a second minus sign and a name, the engine's parser stops at the end of the
  # operand (verified).
  @spec operand_token(tuple(), binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp operand_token(token, rest, acc) do
    if unary_error?(token, acc),
      do: {:syntax_error, :unary, rest},
      else: tokenize(rest, [token | acc])
  end

  defp unary_error?({:str, _content}, acc), do: negated?(acc)

  defp unary_error?({:raw, word}, acc),
    do: String.upcase(word) in ["TRUE", "FALSE"] and negated?(acc)

  defp unary_error?({:ident, _name}, [{:raw, "-"}, {:raw, "-"} = first | before]),
    do: negated?([first | before])

  defp unary_error?(_token, _acc), do: false

  # What stands before a word where an operand is expected decides the
  # error (see `check_where/4`).
  @spec reserved_kind(list()) :: atom()
  @doc false
  def reserved_kind([]), do: :where_unparsed
  def reserved_kind([{:raw, "("} | before]), do: reserved_kind(before)
  def reserved_kind([{:op, _op} | _before]), do: :reserved_operand

  def reserved_kind([{:raw, sign} | before]) when sign in ["+", "-"] do
    if unary_sign?(before), do: reserved_kind(before), else: :reserved_failure
  end

  def reserved_kind([{:raw, op} | _before]) when op in ["*", "/"], do: :reserved_operator

  def reserved_kind([{:raw, word} | _before]) do
    if String.upcase(word) in ["AND", "OR"], do: :reserved_operand, else: :nom
  end

  def reserved_kind(_operand), do: :nom

  @spec unary_sign?(list()) :: boolean()
  defp unary_sign?([]), do: true
  defp unary_sign?([{:op, _op} | _before]), do: true

  defp unary_sign?([{:raw, word} | _before]),
    do: String.upcase(word) in ["(", "AND", "OR", "+", "-", "*", "/"]

  defp unary_sign?(_operand), do: false

  # A comparison operator needs an operand after it; the engine reports the
  # end of the operator.
  @spec operand(binary(), {:op, binary()}, list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp operand(rest, {:op, op} = token, acc) do
    trimmed = InfluxQLLex.trim_blanks(rest)

    cond do
      op in ["=~", "!~"] and not String.starts_with?(trimmed, "/") ->
        {:syntax_error, :regex, rest}

      trimmed == "" ->
        {:syntax_error, :operand, rest}

      InfluxQLLex.cannot_start_operand?(trimmed) and inside_call?(acc) ->
        {:error, "unsupported InfluxQL WHERE: " <> rest}

      InfluxQLLex.cannot_start_operand?(trimmed) ->
        {:syntax_error, :operand, rest}

      op not in ["=~", "!~"] and String.starts_with?(trimmed, "/") ->
        {:syntax_error, :operand, rest}

      true ->
        tokenize(rest, [token | acc])
    end
  end

  # Whether the innermost parenthesis still open is the one of a call (a name stands before it).
  defp inside_call?(tokens), do: inside_call?(tokens, 0)

  defp inside_call?([{:raw, ")"} | rest], pending), do: inside_call?(rest, pending + 1)

  defp inside_call?([{:raw, "("} | rest], 0), do: match?([{:ident, _name} | _more], rest)
  defp inside_call?([{:raw, "("} | rest], pending), do: inside_call?(rest, pending - 1)
  defp inside_call?([_token | rest], pending), do: inside_call?(rest, pending)
  defp inside_call?([], _pending), do: false

  defp open_parens(tokens) do
    Enum.reduce(tokens, 0, fn
      {:raw, "("}, depth -> depth + 1
      {:raw, ")"}, depth -> depth - 1
      _token, depth -> depth
    end)
  end

  @spec rest_after(binary(), binary()) :: binary()
  defp rest_after(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  @spec plain_word(binary(), binary()) :: tuple()
  defp plain_word(upcased, word) do
    if upcased in ~w(TRUE FALSE), do: {:raw, word}, else: {:ident, word}
  end

  # A regular expression ends at the first `/` that no backslash escapes; only
  # `\/` is an escape (it is the slash), any other backslash is the regular
  # expression's own.
  @spec take_regex(binary(), iodata()) :: {binary(), binary()}
  defp take_regex(<<?\\, ?/, rest::binary>>, acc), do: take_regex(rest, ["/" | acc])
  defp take_regex(<<?/, rest::binary>>, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}
  defp take_regex(<<c::utf8, rest::binary>>, acc), do: take_regex(rest, [<<c::utf8>> | acc])
  defp take_regex(<<c, rest::binary>>, acc), do: take_regex(rest, [<<c>> | acc])
  defp take_regex(<<>>, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), <<>>}

  @spec take_until(binary(), char(), iodata()) :: {binary(), binary()}
  defp take_until(<<?\\, c, rest::binary>>, q, acc), do: take_until(rest, q, [<<?\\, c>> | acc])
  defp take_until(<<q, rest::binary>>, q, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}
  defp take_until(<<c::utf8, rest::binary>>, q, acc), do: take_until(rest, q, [<<c::utf8>> | acc])
  defp take_until(<<>>, _q, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), <<>>}
end
