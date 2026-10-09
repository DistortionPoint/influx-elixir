defmodule InfluxElixir.Client.Local.InfluxQLLex do
  @moduledoc false
  # The two tables of the characters of an InfluxQL statement that every reader of the text
  # shares (verified against InfluxDB 3 Core 3.10.1), so that a rule learned for one cannot be
  # forgotten by another:
  #
  #   * the blanks. A space, a tab, a carriage return and a line feed separate tokens; a form
  #     feed and a vertical tab do not (they are refused where the double meets them, see
  #     `InfluxQLParser`). A carriage return is a blank anywhere but directly after a keyword:
  #     the engine's parser takes one blank of `[ \t\n]` at least after a keyword
  #     (`AND\rn < 2`, `SELECT\rn`, `GROUP BY\rhost`, `fill\r(null)` all fail), and any
  #     blanks after that one (`AND \rn`, `AND\n\rn` read)
  #   * the characters that start no operand: after an operator, a connective or a sign, a
  #     character of this table leaves the operand missing, the same error whichever stands
  #     before it (verified for each character after a comparison and after `AND`)

  @doc "Guard: whether a byte is a blank the engine skips between tokens."
  defguard is_blank(byte) when byte in [?\s, ?\t, ?\n, ?\r]

  @doc "The text without the blanks it starts with."
  @spec trim_blanks(binary()) :: binary()
  def trim_blanks(<<byte, rest::binary>>) when is_blank(byte), do: trim_blanks(rest)
  def trim_blanks(text), do: text

  @doc """
  The offset of the first byte at or after `at` in `text` that is no blank (`at` itself when it
  is past the end), so that no reader copies the text to skip the blanks.
  """
  @spec skip_blanks(binary(), non_neg_integer()) :: non_neg_integer()
  def skip_blanks(text, at) do
    case text do
      <<_before::binary-size(at), c, _rest::binary>> when is_blank(c) -> skip_blanks(text, at + 1)
      _other -> at
    end
  end

  @doc "The text without the blanks it ends with."
  @spec trim_trailing_blanks(binary()) :: binary()
  def trim_trailing_blanks(<<>>), do: <<>>

  def trim_trailing_blanks(text) do
    size = byte_size(text) - 1

    if is_blank(:binary.last(text)),
      do: trim_trailing_blanks(binary_part(text, 0, size)),
      else: text
  end

  @doc "The text without the blanks it starts and ends with."
  @spec trim_both_blanks(binary()) :: binary()
  def trim_both_blanks(text), do: text |> trim_blanks() |> trim_trailing_blanks()

  # The blank as a regular expression piece, for the patterns below (see `InfluxQLBlankRegex`).
  @blank InfluxElixir.Client.Local.InfluxQLBlankRegex.blank()

  # The characters after which an operand cannot start: a closing parenthesis, a comparison
  # or arithmetic operator, a comma, and the characters no token of the language starts with
  # (every byte of a non-ASCII character too: identifiers and numbers are ASCII, verified, so
  # `usagé` is `usag` and a leftover, and `٣` is no digit). The patterns that read statements
  # are not Unicode patterns, so that `\w` and `\d` are ASCII and the engine's rules hold.
  #
  # A `$` starts a bind parameter (`$a`, `$1`, `$"a b"`, verified) and so starts an operand,
  # unless nothing that names one follows it.
  @no_operand "(?:[" <>
                Regex.escape(")=!<>*%&|^,;#@?}][\\`{~") <> "\\x80-\\xFF]|\\$(?![\\w\"]))"

  # What stands directly against a connective (`AND#n`) and is no blank, operator, quote or
  # parenthesis: the connective is not read as one and the statement is left over from it
  # (verified for each of these characters and for `é`, `٣`, U+2003 and U+00A0).
  @glued_set "[#@$?}\\]\\[\\\\`{~]|[\\x80-\\xFF]"
  @glued Regex.compile!("\\A(?:" <> @glued_set <> ")")

  @doc "Whether the text, which follows a connective directly, starts with a glued character."
  @spec glued?(binary()) :: boolean()
  def glued?(text), do: Regex.match?(@glued, text)

  @doc """
  The bind parameter (`$name`, `$1`, `$"quoted name"`) the text starts with and what follows
  it, or `nil` when it starts with none.
  """
  @spec take_param(binary()) :: {binary(), binary()} | nil
  def take_param(text) do
    with [param] <- Regex.run(~r/\A\$(?:\w+|"(?:[^"\\]|\\.)*")/s, text) do
      {param, binary_part(text, byte_size(param), byte_size(text) - byte_size(param))}
    end
  end

  # What follows a connective or a sign and can start no operand, however many opening
  # parentheses and signs come between.
  @operand_missing Regex.compile!("\\A(?:" <> @blank <> "|[(+\\-])*" <> @no_operand)

  # What can start no operand after a comparison operator (verified: the error is at the end
  # of the operator): one of those characters, a connective or a dot with no digit after it.
  # A connective with a quote, a carriage return or a glued character directly against it is
  # a name there, which starts an operand (see `InfluxQLTokens`).
  @cannot_start Regex.compile!(
                  "^(?:" <>
                    @no_operand <>
                    "|[-+]?\\.(?!\\d)|(?:AND|OR)\\b(?!['\"\\r]|" <> @glued_set <> "))",
                  "i"
                )

  # A connective that a blank or a parenthesis follows (`100OR 1`): a number may end before it.
  @spaced_connective Regex.compile!("^(?:AND|OR)(?=" <> @blank <> "|\\()", "i")

  @doc "Whether the text, after any blanks, parentheses and signs, starts no operand."
  @spec operand_missing?(binary()) :: boolean()
  def operand_missing?(text), do: Regex.match?(@operand_missing, text)

  @doc "Whether the text, where an operand follows a comparison operator, starts none."
  @spec cannot_start_operand?(binary()) :: boolean()
  def cannot_start_operand?(text), do: Regex.match?(@cannot_start, text)

  @doc "Whether the text starts with a connective that a blank or a parenthesis follows."
  @spec spaced_connective?(binary()) :: boolean()
  def spaced_connective?(text), do: Regex.match?(@spaced_connective, text)

  @doc """
  Whether a carriage return stands directly after the keyword that ends at `at` in `text`:
  the keyword is then not read as one.
  """
  @spec cr_after?(binary(), non_neg_integer()) :: boolean()
  def cr_after?(text, at), do: binary_part(text, at, min(1, byte_size(text) - at)) == "\r"
end
