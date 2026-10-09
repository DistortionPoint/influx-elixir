defmodule InfluxElixir.Client.Local.InfluxQLArgs do
  @moduledoc false
  # The arguments of a call as the engine's parser reads them (verified against InfluxDB 3
  # Core 3.10.1): where the parser fails when they are not `expression {, expression}` closed
  # by `)`. The engine reports such a failure as `Parsing Failure: Nom(<text from there>)`.
  #
  #   * after an operand only `,`, `)` or a binary operator may follow; anything else, a name,
  #     a digit, a quote, a `.`, `:`, `#`, `}`, or the end of the text, is where the parser
  #     fails (`mean(usage x)`, `fill(1.)`, `fill(1e2)`, `fill(0x1)`, `1us`, `1.5h`)
  #   * a `,` that no operand follows is where it fails (`f(a,)`, `f(a, , b)`, `f(,)`); so is
  #     a comparison operator where the first argument should start (`f(=~n)`)
  #   * an operator that no operand follows fails at the operator for `* / % &`, and where the
  #     operand should start (the sign of a signed operand, else the `)` or `,`) for `+ - | ^`
  #   * a sign that no operand follows fails at the sign (`f(+)`, `f(-\f1)`: a form feed is
  #     no blank to the engine)
  #   * a parenthesised operand whose contents are not one expression closed by `)` fails where
  #     it starts (`f((a b))`); a failure inside it stands (`f((a +))` fails at the second `)`)
  #   * a name with a `.` and no name after it is no operand (`f(v1.)`, `f(linear0.5)`)
  #
  # What is not verified (a regular expression, a bind parameter, a reserved word where an
  # operand starts, a character that starts no operand, a type that is none of the engine's,
  # `AND`/`OR`) is `:unknown`, and the caller refuses or leaves the text to its other checks.
  # The text is masked: the inside of the literals and the comments are blanks of the same
  # size.

  alias InfluxElixir.Client.Local.{InfluxQLLex, InfluxQLText}

  require InfluxQLLex

  @typedoc "Where a call's arguments fail (`:eot`: at the end of the text), or that they read."
  @type result :: {:ok, non_neg_integer()} | {:fail, non_neg_integer() | :eot} | :unknown

  # What reading an operand or an expression gives: where it stops, where no operand starts,
  # where a sign has no operand after it, a failure that stands (`:plain_fail` is that of an
  # operator after which the engine does not fail but leaves the text over, which holds in a
  # call's arguments only), or that the double does not know.
  @typep read ::
           {:ok, non_neg_integer()}
           | {:none, non_neg_integer()}
           | {:soft, non_neg_integer()}
           | {:fail, non_neg_integer() | :eot}
           | {:plain_fail, non_neg_integer()}
           | :unknown

  # Operators after which a missing operand is a failure where the operand should be.
  @cut_operators [?+, ?-, ?|, ?^]
  @plain_operators [?*, ?/, ?%, ?&]

  # A number, or a duration: a count of each unit the engine knows, then nothing else.
  @number ~r/\A(?:(?:\d+(?:ns|ms|u|µ|s|m|h|d|w))+|\d*\.\d+|\d+)/
  @name ~r/\A[A-Za-z_]\w*/
  # The characters the parser is known to stop at after an operand.
  @stops ~r/\A[A-Za-z0-9_.'"#:}!=<>\[\]{~\\@?`$\x80-\xFF]/
  @types ~w(float integer unsigned string boolean field tag)
  @param ~r/\A\$[\w"]/
  @param_token ~r/\A\$(?:\w+|"[^"]*"?)/
  @no_operand ~w(# @ { } [ ] \\ ~ ` ; : ? % & | ^ < > = ! . $)

  @doc """
  Reads the arguments of the call whose `(` stands at `open_at` in `text`: `{:ok, stop}` where
  the `)` ends, or where the parser fails.
  """
  @spec read(binary(), non_neg_integer()) :: result()
  def read(text, open_at) do
    case arguments(text, open_at + 1, :where) do
      {:ok, stop} -> {:ok, stop}
      {:fail, at} -> {:fail, at}
      _no_operand_or_unknown -> :unknown
    end
  end

  @doc """
  Whether `text` (one item of a select list, masked) is an expression the engine's parser
  reads whole, with an alias after it or none: a name, a number, a call whose arguments read,
  a type (`usage::field`), arithmetic of those. What it does not place (a regular expression,
  a reserved word, `DISTINCT`) is not.
  """
  @spec item?(binary()) :: boolean()
  def item?(text) do
    case expression(text, InfluxQLLex.skip_blanks(text, 0), :select) do
      {:ok, stop} -> aliased?(binary_part(text, stop, byte_size(text) - stop))
      _unread -> false
    end
  end

  defp aliased?(rest) do
    InfluxQLLex.trim_both_blanks(rest) == "" or
      Regex.match?(~r/\A[ \t]+AS[ \t]+(?:[A-Za-z_]\w*|"_*")[ \t]*\z/i, rest)
  end

  @doc """
  Where the select item `text` (masked) fails to read as an expression, if it does: the arguments
  of a call that do not read, or an operator `+ - | ^` with no operand after it. The item is
  read from its start, so a call that stands after something that is no operand
  (`usage fill(`, `1e2derivative(`) is not read, the statement being unreadable before it.
  """
  @spec item_failure(binary()) :: {:fail, non_neg_integer() | :eot} | nil
  def item_failure(text) do
    case expression(text, InfluxQLLex.skip_blanks(text, 0), :select) do
      {:fail, at} -> {:fail, at}
      _read_or_unknown -> nil
    end
  end

  @doc """
  Whether no field starts the text (after any signs): a parenthesis whose contents are not an
  expression closed by `)` is no operand, and the select list fails where it starts.
  """
  @spec no_field?(binary()) :: boolean()
  def no_field?(text) do
    at = InfluxQLLex.skip_blanks(text, 0)

    char(text, at) == ?( and match?({:none, ^at}, expression(text, at, :select))
  end

  @doc """
  Where a select item that reads as an expression is followed by what is no part of it: a
  name, a number or a quoted text, other than an alias (`usage x`, `usage fill(1)`,
  `1e2derivative(f)`). The engine reads the item, finds `FROM` wanted, and leaves the whole
  statement unparsed.
  """
  @spec item_leftover(binary()) :: non_neg_integer() | nil
  def item_leftover(text) do
    case expression(text, InfluxQLLex.skip_blanks(text, 0), :select) do
      {:ok, stop} ->
        at = InfluxQLLex.skip_blanks(text, stop)
        <<_before::binary-size(at), rest::binary>> = text

        if Regex.match?(~r/\AAS(?![\w])/i, rest),
          do: alias_leftover(text, at, rest),
          else: operand_leftover(at, rest)

      _reads_whole_or_unknown ->
        nil
    end
  end

  defp operand_leftover(at, rest) do
    with true <- Regex.match?(~r/\A[A-Za-z0-9_'"\[\]{}~\\@?`$#:\x80-\xFF]/, rest),
         nil <- InfluxQLText.reserved_start(rest, plain: true) do
      at
    else
      _no_leftover -> nil
    end
  end

  # What stands after the alias of an item: the item is read whole, and the text behind it (a
  # character that continues nothing) is left over.
  defp alias_leftover(text, at, rest) do
    with [alias_text, word] <- Regex.run(~r/\AAS[ \t\r\n]+([A-Za-z_]\w*|"[^"]*")/i, rest),
         nil <- InfluxQLText.reserved_start(word, plain: true),
         after_alias = at + byte_size(alias_text),
         <<_before::binary-size(after_alias), tail::binary>> = text,
         trimmed = InfluxQLLex.trim_blanks(tail),
         true <-
           Regex.match?(~r/\A[A-Za-z0-9_'"\[\]{}~\\@?`$#:|^&*%+\-\/=<>!.\x80-\xFF]/, trimmed) do
      after_alias + byte_size(tail) - byte_size(trimmed)
    else
      _no_leftover -> nil
    end
  end

  # The arguments of a call: a failure of an operator that leaves the text over is the call's
  # failure from here on.
  @spec arguments(binary(), non_neg_integer(), atom()) :: read()
  defp arguments(text, from, mode) do
    at = InfluxQLLex.skip_blanks(text, from)

    result =
      if char(text, at) == ?),
        do: {:ok, at + 1},
        else: first_argument(text, at, mode)

    case result do
      {:plain_fail, at} -> {:fail, at}
      other -> other
    end
  end

  # No operand where the first argument should start: a `,` or a group that does not read is where
  # it fails.
  defp first_argument(text, at, mode) do
    case expression(text, at, mode) do
      {:ok, stop} -> after_argument(text, InfluxQLLex.skip_blanks(text, stop), mode)
      {:none, none_at} -> none_at(text, none_at)
      {:soft, sign_at} -> {:fail, sign_at}
      other -> other
    end
  end

  defp none_at(text, at) do
    case char(text, at) do
      nil -> {:fail, :eot}
      _comma_or_group -> {:fail, at}
    end
  end

  # `,` and the next argument, or the `)` that closes the list.
  defp after_argument(text, at, mode) do
    case char(text, at) do
      ?) -> {:ok, at + 1}
      ?, -> next_argument(text, at, mode)
      nil -> {:fail, :eot}
      _leftover -> leftover(text, at)
    end
  end

  # An argument that does not start after a `,` takes the `,` back: the list is left from it,
  # when the next character is one the parser is known to stop at.
  defp next_argument(text, comma, mode) do
    next = InfluxQLLex.skip_blanks(text, comma + 1)

    case expression(text, next, mode) do
      {:ok, stop} -> after_argument(text, InfluxQLLex.skip_blanks(text, stop), mode)
      {:none, _at} -> {:fail, comma}
      {:soft, _at} -> :unknown
      other -> other
    end
  end

  # What stands after an operand where `,`, `)` or an operator should: the parser fails there.
  defp leftover(text, at) do
    <<_before::binary-size(at), rest::binary>> = text

    if Regex.match?(@stops, rest), do: {:fail, at}, else: :unknown
  end

  # An operand, then the binary operators and their operands.
  # `mode` is where the expression stands: `:where` (a condition) or `:select` (a select list).
  @spec expression(binary(), non_neg_integer(), atom()) :: read()
  defp expression(text, at, mode) do
    case operand(text, at, mode) do
      {:ok, stop} -> operators(text, stop, mode)
      other -> other
    end
  end

  defp operators(text, stop, mode) do
    at = InfluxQLLex.skip_blanks(text, stop)
    operator = char(text, at)

    cond do
      operator in @cut_operators -> cut(text, at, mode)
      operator in @plain_operators -> plain(text, at, mode)
      true -> {:ok, stop}
    end
  end

  defp cut(text, operator_at, mode) do
    case operand(text, InfluxQLLex.skip_blanks(text, operator_at + 1), mode) do
      {:ok, stop} -> operators(text, stop, mode)
      {:none, at} -> {:fail, at_or_eot(text, at)}
      {:soft, at} -> {:fail, at}
      other -> other
    end
  end

  defp plain(text, operator_at, mode) do
    case operand(text, InfluxQLLex.skip_blanks(text, operator_at + 1), mode) do
      {:ok, stop} -> operators(text, stop, mode)
      {:none, _at} -> {:plain_fail, operator_at}
      {:soft, _at} -> :unknown
      other -> other
    end
  end

  defp at_or_eot(text, at), do: if(at >= byte_size(text), do: :eot, else: at)

  # An operand: signs, then a number, a name (with a type, or a call), a string, a `*` or a
  # parenthesised expression.
  @spec operand(binary(), non_neg_integer(), atom()) :: read()
  defp operand(text, at, mode) do
    case char(text, at) do
      sign when sign in [?+, ?-] -> signed(text, at, mode)
      _other -> primary(text, at, mode)
    end
  end

  # A sign before `*` (in a select list) or a regular expression is the engine's error for a
  # unary expression, not a failure of the arguments. In a condition's call a `*` is no
  # operand, and the sign fails (`abs(-*)` is left from the sign).
  defp signed(text, sign_at, mode) do
    next = char(text, InfluxQLLex.skip_blanks(text, sign_at + 1))

    if next in [?/, ?'] or (next == ?* and mode == :select),
      do: :unknown,
      else: signed_operand(text, sign_at, mode)
  end

  defp signed_operand(text, sign_at, mode) do
    case operand(text, InfluxQLLex.skip_blanks(text, sign_at + 1), mode) do
      {:ok, stop} -> {:ok, stop}
      {:none, _at} -> {:soft, sign_at}
      {:soft, _at} -> {:soft, sign_at}
      other -> other
    end
  end

  defp primary(text, at, mode) do
    <<_before::binary-size(at), rest::binary>> = text
    primary(classify(rest), text, at, rest, mode)
  end

  defp classify(""), do: :end

  defp classify(rest) do
    cond do
      Regex.match?(@number, rest) -> :number
      Regex.match?(@name, rest) -> :name
      Regex.match?(@param, rest) -> :param
      true -> classify_symbol(binary_part(rest, 0, 1))
    end
  end

  # A form feed and a vertical tab are no blanks to the engine, and start no operand.
  defp classify_symbol(symbol) when symbol in ["'", "\""], do: :string
  defp classify_symbol("("), do: :group
  defp classify_symbol("*"), do: :star
  defp classify_symbol(symbol) when symbol in [",", ")", "\f", "\v"], do: :none
  # A character that starts no operand (verified for each: the parser fails where the operand
  # should start, or at the comma before it), a non-ASCII byte too.
  defp classify_symbol(<<byte>>) when byte >= 0x80, do: :none
  defp classify_symbol(symbol) when symbol in @no_operand, do: :none
  defp classify_symbol(_other), do: :other

  defp primary(:end, _text, at, _rest, _mode), do: {:none, at}

  # A bind parameter (`$a`, `$1`, `$"a b"`) is an operand.
  defp primary(:param, _text, at, rest, _mode) do
    [param] = Regex.run(@param_token, rest)
    {:ok, at + byte_size(param)}
  end

  defp primary(:none, _text, at, _rest, _mode), do: {:none, at}
  defp primary(:other, _text, _at, _rest, _mode), do: :unknown

  defp primary(:number, _text, at, rest, _mode) do
    [number] = Regex.run(@number, rest)
    {:ok, at + byte_size(number)}
  end

  defp primary(:string, _text, at, rest, _mode) do
    # The closing quote is optional: the text may end inside the literal, which is its own error.
    size =
      case :binary.match(rest, binary_part(rest, 0, 1), scope: {1, byte_size(rest) - 1}) do
        {close, 1} -> close + 1
        :nomatch -> byte_size(rest)
      end

    {:ok, at + size}
  end

  # A `*` is an operand in a select list (`count(*)`), and none in a condition's call: the
  # parser fails where the `*` stands (verified: `abs(*)`, `now( *`, `abs((*))`, `abs(1, *)`).
  defp primary(:star, _text, at, _rest, :where), do: {:none, at}

  defp primary(:star, text, at, _rest, :select) do
    if char(text, at + 1) == ?:, do: :unknown, else: {:ok, at + 1}
  end

  # A group whose contents are not one expression closed by `)` fails where it starts: it is an
  # operand that was not there. A failure inside it stands.
  defp primary(:group, text, at, _rest, mode) do
    case expression(text, InfluxQLLex.skip_blanks(text, at + 1), mode) do
      {:ok, stop} -> group_close(text, at, InfluxQLLex.skip_blanks(text, stop))
      {:fail, inside} -> {:fail, inside}
      {:plain_fail, _inside} -> :unknown
      :unknown -> :unknown
      _unread -> {:none, at}
    end
  end

  defp primary(:name, text, at, rest, mode) do
    [name] = Regex.run(@name, rest)

    if operand_name?(rest, name),
      do: name_tail(text, at, at + byte_size(name), mode),
      else: :unknown
  end

  # A name that can be an operand: no reserved word (read as one where a blank, an operator or
  # the end follows it), and no connective or `NOT`.
  defp operand_name?(rest, name) do
    InfluxQLText.reserved_start(rest) == nil and String.downcase(name) not in ["and", "or", "not"]
  end

  defp group_close(
         text,
         group_at,
         at
       ) do
    if char(text, at) == ?), do: {:ok, at + 1}, else: {:none, group_at}
  end

  # A name, then its type (`usage::field`) or the arguments of the call it names. A `.` makes it
  # a dotted name, which needs another name after the dot.
  defp name_tail(text, name_at, stop, mode) do
    case text do
      <<_before::binary-size(stop), "::", rest::binary>> ->
        typed(text, rest, stop)

      <<_before::binary-size(stop), ".", rest::binary>> ->
        dotted(text, name_at, stop + 1, rest)

      _no_type ->
        at = InfluxQLLex.skip_blanks(text, stop)
        if char(text, at) == ?(, do: call(text, at, mode), else: {:ok, stop}
    end
  end

  # The names after a `.` (blanks may stand after the dot: `m. f` is `m.f`, verified): a dot
  # with no name after it is no operand, a name read to its end is an operand (a call or a type
  # after a dotted name is not placed).
  @spec dotted(binary(), non_neg_integer(), non_neg_integer(), binary()) :: read()
  defp dotted(text, name_at, after_dot, rest) do
    trimmed = InfluxQLLex.trim_blanks(rest)
    start = after_dot + byte_size(rest) - byte_size(trimmed)

    case Regex.run(~r/\A(?:[A-Za-z_]\w*|"_*")/, trimmed) do
      [part] ->
        stop = start + byte_size(part)

        case text do
          <<_before::binary-size(stop), ".", more::binary>> ->
            dotted(text, name_at, stop + 1, more)

          <<_before::binary-size(stop), "::", _more::binary>> ->
            :unknown

          _end ->
            if char(text, InfluxQLLex.skip_blanks(text, stop)) == ?(,
              do: :unknown,
              else: {:ok, stop}
        end

      nil ->
        {:none, name_at}
    end
  end

  # The type of the engine's after `::`, and nothing of a second.
  defp typed(text, rest, stop) do
    with [type] <- Regex.run(@name, rest),
         true <- String.downcase(type) in @types,
         end_at = stop + 2 + byte_size(type),
         false <- String.starts_with?(binary_part(text, end_at, byte_size(text) - end_at), "::") do
      {:ok, end_at}
    else
      _unknown_type -> :unknown
    end
  end

  # The arguments of a call inside an expression: its failures stand.
  defp call(text, open_at, mode) do
    case arguments(text, open_at + 1, mode) do
      {:ok, stop} -> {:ok, stop}
      {:fail, at} -> {:fail, at}
      _no_operand_or_unknown -> :unknown
    end
  end

  @spec char(binary(), non_neg_integer()) :: byte() | nil
  defp char(text, at) when at < byte_size(text), do: :binary.at(text, at)
  defp char(_text, _at), do: nil
end
