defmodule InfluxElixir.Client.Local.InfluxQLTokens do
  @moduledoc """
  The tokens of an InfluxQL `WHERE`, read as the engine's parser reads them:
  strings, quoted identifiers, regular expressions, numbers, durations,
  operators and words. What the parser cannot read comes back as
  `{:syntax_error, kind, rest}` with the text left from the error, which
  `InfluxElixir.Client.Local.InfluxQLCheck` turns into the engine's body.
  """

  alias InfluxElixir.Client.Local.InfluxQLReserved

  @max_unsigned 18_446_744_073_709_551_615
  @max_signed 9_223_372_036_854_775_807

  @duration_ns %{
    "ns" => 1,
    "u" => 1_000,
    "µ" => 1_000,
    "ms" => 1_000_000,
    "s" => 1_000_000_000,
    "m" => 60_000_000_000,
    "h" => 3_600_000_000_000,
    "d" => 86_400_000_000_000,
    "w" => 604_800_000_000_000
  }

  @doc false
  @spec time?(term()) :: boolean()
  def time?({:ident, name}), do: String.downcase(name) == "time"
  def time?(_token), do: false

  @spec tokenize(binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  @doc false
  def tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  def tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r], do: tokenize(rest, acc)

  def tokenize(<<?', rest::binary>>, acc) do
    {content, rest} = take_until(rest, ?', [])
    # InfluxQL escapes a quote with a backslash, SQL by doubling it.
    tokenize(rest, [{:str, String.replace(content, "\\'", "''")} | acc])
  end

  def tokenize(<<?", rest::binary>>, acc) do
    {name, rest} = take_until(rest, ?", [])
    tokenize(rest, [{:ident, String.replace(name, "\\\"", "\"")} | acc])
  end

  def tokenize(<<?/, rest::binary>>, [{:op, op} | _tokens] = acc) when op in ["=~", "!~"] do
    {pattern, rest} = take_until(rest, ?/, [])
    tokenize(rest, [{:regex, String.replace(pattern, "\\/", "/")} | acc])
  end

  def tokenize(<<op::binary-size(2), rest::binary>>, acc)
      when op in ["=~", "!~", "!=", "<>", "<=", ">="],
      do: operand(rest, {:op, op}, acc)

  def tokenize(<<c, rest::binary>>, acc) when c in [?=, ?<, ?>],
    do: operand(rest, {:op, <<c>>}, acc)

  def tokenize(<<c, rest::binary>>, acc) when c in [?(, ?), ?+, ?-, ?*, ?/, ?,],
    do: tokenize(rest, [{:raw, <<c>>} | acc])

  def tokenize(text, acc) do
    case Regex.run(
           ~r/^(?:(\d+)(ns|ms|u|µ|s|m|h|d|w)\b|(\d*\.\d+|\d+)|(now\s*\(\s*\))|([A-Za-z_]\w*))/u,
           text
         ) do
      [full, n, unit] ->
        count = String.to_integer(n)

        cond do
          count > @max_unsigned -> {:syntax_error, :overflow, rest_after(text, n)}
          count > @max_signed -> {:syntax_error, :nom, rest_after(text, n)}
          true -> duration_token(count, unit, full, text, acc)
        end

      [full, "", "", number] ->
        number_token(number, rest_after(text, full), acc)

      [full, "", "", "", _now] ->
        tokenize(rest_after(text, full), [{:raw, "now()"} | acc])

      [full, "", "", "", "", word] ->
        word_token(String.upcase(word), word, rest_after(text, full), acc)

      nil ->
        {:error, "unsupported InfluxQL WHERE: #{text}"}
    end
  end

  @spec duration_token(non_neg_integer(), binary(), binary(), binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp duration_token(count, unit, full, text, acc) do
    duration = {:duration, count * Map.fetch!(@duration_ns, unit), full}
    tokenize(rest_after(text, full), [duration | acc])
  end

  # A number that a letter, digit, underscore or dot follows is cut short
  # there, which the engine cannot continue from.
  @spec number_token(binary(), binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp number_token(number, rest, acc) do
    case rest do
      <<c, _more::binary>> when c in ?0..?9 or c in ?a..?z or c in ?A..?Z or c in [?_, ?.] ->
        {:syntax_error, :nom, rest}

      _ended ->
        case integer_overflow(number, acc) do
          nil -> tokenize(rest, [{:number, number} | acc])
          kind -> {:syntax_error, kind, rest}
        end
    end
  end

  # An integer literal fits the unsigned 64-bit range, a negated one the
  # signed range; a number with a fraction has no range.
  @spec integer_overflow(binary(), list()) :: :overflow | :signed_overflow | nil
  defp integer_overflow(number, acc) do
    case Integer.parse(number) do
      {n, ""} when n > @max_unsigned -> :overflow
      {n, ""} when n > @max_signed + 1 -> if negated?(acc), do: :signed_overflow
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
    if Regex.match?(~r/^\s*(?!(?:AND|OR)\b)[A-Za-z_0-9."']/i, rest),
      do: {:syntax_error, :nom, String.trim_leading(rest)},
      else: tokenize(rest, [{:ident, word} | acc])
  end

  defp word_token(upcased, word, rest, acc) when upcased in ["AND", "OR"] do
    cond do
      reserved_kind(acc) != :nom -> {:syntax_error, reserved_kind(acc), word <> rest}
      String.trim(rest) == "" -> {:syntax_error, :operand, rest}
      true -> tokenize(rest, [{:raw, word} | acc])
    end
  end

  defp word_token(upcased, word, rest, acc) do
    if InfluxQLReserved.reserved?(word) and not String.starts_with?(rest, ":"),
      do: {:syntax_error, reserved_kind(acc), word <> rest},
      else: tokenize(rest, [plain_word(upcased, word) | acc])
  end

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
    trimmed = String.trim_leading(rest)

    cond do
      op in ["=~", "!~"] and not String.starts_with?(trimmed, "/") ->
        {:syntax_error, :regex, rest}

      trimmed == "" ->
        {:syntax_error, :operand, rest}

      cannot_start_operand?(trimmed) ->
        {:syntax_error, :operand, rest}

      true ->
        tokenize(rest, [token | acc])
    end
  end

  # A closing parenthesis, a connective or a dot with no digit after it.
  @spec cannot_start_operand?(binary()) :: boolean()
  defp cannot_start_operand?(text),
    do: Regex.match?(~r/^(?:\)|[-+]?\.(?!\d)|(?:AND|OR)\b)/i, text)

  @spec rest_after(binary(), binary()) :: binary()
  defp rest_after(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  @spec plain_word(binary(), binary()) :: tuple()
  defp plain_word(upcased, word) do
    if upcased in ~w(TRUE FALSE), do: {:raw, word}, else: {:ident, word}
  end

  @spec take_until(binary(), char(), iodata()) :: {binary(), binary()}
  defp take_until(<<?\\, c, rest::binary>>, q, acc), do: take_until(rest, q, [<<?\\, c>> | acc])
  defp take_until(<<q, rest::binary>>, q, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}
  defp take_until(<<c::utf8, rest::binary>>, q, acc), do: take_until(rest, q, [<<c::utf8>> | acc])
  defp take_until(<<>>, _q, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), <<>>}
end
