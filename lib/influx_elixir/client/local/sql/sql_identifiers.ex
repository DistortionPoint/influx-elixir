defmodule InfluxElixir.Client.Local.SQLIdentifiers do
  @moduledoc false
  # DataFusion's identifier rules, applied to a SQL text before
  # `InfluxElixir.Client.Local.SQLParser` reads it (verified against
  # InfluxDB 3 Core):
  #
  #   * an unquoted identifier is folded to lower case — column, table, alias
  #     and CTE names alike: `SELECT Host FROM Cpu` reads column `host` of
  #     table `cpu`, and `AVG(v) AS Avg_V` answers `avg_v`. Only the ASCII
  #     letters fold: `Fé` is `fé`, and `FÉ` is `fÉ`, a column that does not
  #     exist. A name may hold letters and digits of any script
  #   * a double-quoted identifier keeps its case: `"Host"` is column `Host`
  #   * string literals (`'Abc'`) and `$name` placeholders are left as they are
  #   * a number ends where the engine's tokenizer ends it, and a word right after it is a
  #     word of its own: `1_000` is `1` and the alias `_000`, `0b1` is `0` and `b1`
  #
  # A quoted identifier that is a plain word is written back bare, so the
  # parser — which folds nothing — sees its exact name. One that needs its
  # quotes (a space, a dot, a keyword such as `"order"`) keeps them.
  #
  # It also owns what the passes that read a SQL text share: the characters of a word and
  # the reader of a quoted token.

  # Words the parser reads as structure: a quoted column of that name keeps
  # its quotes rather than turn into the keyword.
  @keywords ~w(select distinct on from where and or not in is null between like ilike
               group by order asc desc nulls first last limit offset as with cross join
               interval true false cast having union except intersect minus left right inner
               full natural outer using window qualify fetch all)

  @number ~r/\A(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/

  @doc "Folds unquoted identifiers to lower case and unwraps plain quoted ones."
  @spec normalize(binary()) :: binary()
  def normalize(sql), do: sql |> scan([]) |> IO.iodata_to_binary()

  @spec scan(binary(), iodata()) :: iodata()
  defp scan(<<>>, acc), do: Enum.reverse(acc)

  defp scan(<<?', rest::binary>>, acc) do
    {literal, rest} = quoted_or_rest(rest, ?')
    scan(rest, [[?', literal, ?'] | acc])
  end

  defp scan(<<?", rest::binary>>, acc) do
    {name, rest} = quoted_or_rest(rest, ?")
    scan(rest, [quoted_identifier(name) | acc])
  end

  defp scan(<<?$, rest::binary>>, acc) do
    {name, rest} = take_word(rest, [])
    scan(rest, [[?$, name] | acc])
  end

  # `0x1F` is one token: a binary value to the engine.
  defp scan(<<?0, x, _rest::binary>> = sql, acc) when x in [?x, ?X] do
    {number, rest} = take_word(sql, [])
    scan(rest, [number | acc])
  end

  defp scan(<<c, _rest::binary>> = sql, acc) when c in ?0..?9, do: scan_number(sql, acc)

  defp scan(<<?., d, _rest::binary>> = sql, acc) when d in ?0..?9, do: scan_number(sql, acc)

  defp scan(<<c::utf8, rest::binary>> = sql, acc) do
    if word_start?(c) do
      {word, rest} = take_word(sql, [])
      scan(rest, [String.downcase(IO.iodata_to_binary(word), :ascii) | acc])
    else
      scan(rest, [<<c::utf8>> | acc])
    end
  end

  # A number (`1e5`, `2.5`) is copied whole, so its exponent is not a word; the word after
  # it is set apart by a space, which the passes after this one read as the tokenizer does.
  @spec scan_number(binary(), iodata()) :: iodata()
  defp scan_number(sql, acc) do
    [number] = Regex.run(@number, sql)
    rest = binary_part(sql, byte_size(number), byte_size(sql) - byte_size(number))

    case rest do
      <<c::utf8, _more::binary>> -> scan(rest, [separator(c), number | acc])
      _end -> scan(rest, [number | acc])
    end
  end

  @spec separator(char()) :: binary()
  defp separator(c), do: if(word_char?(c), do: " ", else: "")

  @spec quoted_or_rest(binary(), char()) :: {binary(), binary()}
  defp quoted_or_rest(text, mark) do
    case take_quoted(text, mark) do
      {:ok, body, rest} -> {body, rest}
      :error -> {text, <<>>}
    end
  end

  @doc """
  The body of a quoted token whose opening `mark` was read, a doubled quote kept doubled,
  and the text after the closing quote; `:error` when the token is not closed.
  """
  @spec take_quoted(binary(), char()) :: {:ok, binary(), binary()} | :error
  def take_quoted(text, mark), do: take_quoted(text, mark, text, 0)

  @spec take_quoted(binary(), char(), binary(), non_neg_integer()) ::
          {:ok, binary(), binary()} | :error
  defp take_quoted(<<mark, mark, rest::binary>>, mark, whole, at),
    do: take_quoted(rest, mark, whole, at + 2)

  defp take_quoted(<<mark, rest::binary>>, mark, whole, at),
    do: {:ok, binary_part(whole, 0, at), rest}

  defp take_quoted(<<c::utf8, rest::binary>>, mark, whole, at),
    do: take_quoted(rest, mark, whole, at + byte_size(<<c::utf8>>))

  defp take_quoted(_text, _mark, _whole, _at), do: :error

  # An identifier starts with a letter or `_` and goes on with letters,
  # digits and `_`, in any script.
  @spec take_word(binary(), iodata()) :: {iodata(), binary()}
  defp take_word(<<c::utf8, rest::binary>> = input, acc) do
    if word_char?(c), do: take_word(rest, [<<c::utf8>> | acc]), else: {Enum.reverse(acc), input}
  end

  defp take_word(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  @doc "Whether a character starts an identifier: a letter of any script, or `_`."
  @spec word_start?(char()) :: boolean()
  def word_start?(c) when c in ?a..?z or c in ?A..?Z or c == ?_, do: true
  def word_start?(c) when c < 128, do: false
  def word_start?(c), do: Regex.match?(~r/\A\p{L}\z/u, <<c::utf8>>)

  @doc "Whether a character goes on an identifier: a letter or digit of any script, or `_`."
  @spec word_char?(char()) :: boolean()
  def word_char?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_, do: true
  def word_char?(c) when c < 128, do: false
  def word_char?(c), do: Regex.match?(~r/\A[\p{L}\p{N}]\z/u, <<c::utf8>>)

  @doc "Whether a byte is an ASCII letter, digit or `_`, for the passes that read bytes."
  @spec word_byte?(byte()) :: boolean()
  def word_byte?(byte), do: byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?_

  @spec quoted_identifier(binary()) :: iodata()
  defp quoted_identifier(name) do
    if Regex.match?(~r/\A[\p{L}_][\p{L}\p{N}_]*\z/u, name) and
         String.downcase(name) not in @keywords,
       do: name,
       else: [?", name, ?"]
  end
end
