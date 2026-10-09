defmodule InfluxElixir.Client.Local.InfluxQLShowText do
  @moduledoc false
  # What the pieces of the `SHOW` parser (`InfluxQLShowParser`,
  # `InfluxQLShowClauses`, `InfluxQLShowCondition`) share: reading the
  # scanned statement byte by byte (blanks, words, keywords) and the names,
  # measurement lists and regular expressions its clauses are made of.
  #
  # The statement is read through its mask (`ctx.masked`: the inside of every
  # literal blanked to `_`, comments blanked to spaces), so a keyword inside a
  # literal is no keyword; the text of a name or a regular expression is read
  # from `ctx.clean`. Every position is a byte offset into the statement as
  # sent.

  alias InfluxElixir.Client.Local.{InfluxQLError, InfluxQLLex, InfluxQLRegex, InfluxQLText}

  require InfluxQLLex

  @typedoc "The scanned statement."
  @type ctx :: %{
          raw: binary(),
          clean: binary(),
          masked: binary(),
          size: non_neg_integer(),
          bad: nil | {atom(), non_neg_integer()}
        }

  @typedoc "A parse result: the spec read so far and where the next clause starts."
  @type step :: {:ok, map(), non_neg_integer()} | :none | {:error, term()}

  @prefix "error in InfluxQL statement: parsing error: "

  @doc "The start of every parse error body of the engine."
  @spec prefix() :: binary()
  def prefix, do: @prefix

  @doc "The engine's parse error `message` at byte `at`."
  @spec error(binary(), non_neg_integer()) :: {:error, {:engine, binary()}}
  def error(message, at), do: {:error, {:engine, "#{@prefix}#{message} at pos #{at}"}}

  @doc "The statement as sent from `at` on."
  @spec rest(ctx(), non_neg_integer()) :: binary()
  def rest(ctx, at), do: binary_part(ctx.raw, at, ctx.size - at)

  @doc "Whether the masked statement has `text` at `at`."
  @spec rest_starts?(ctx(), non_neg_integer(), binary()) :: boolean()
  def rest_starts?(ctx, at, text) do
    size = byte_size(text)
    at + size <= ctx.size and binary_part(ctx.masked, at, size) == text
  end

  @doc "The byte of the masked statement at `at`, `nil` past its end."
  @spec at_byte(ctx(), non_neg_integer()) :: binary() | nil
  def at_byte(ctx, at) when at < ctx.size, do: binary_part(ctx.masked, at, 1)
  def at_byte(_ctx, _at), do: nil

  @doc "Whether a blank stands at `at`."
  @spec ws?(ctx(), non_neg_integer()) :: boolean()
  def ws?(ctx, at), do: match?(<<c>> when InfluxQLLex.is_blank(c), at_byte(ctx, at))

  @doc "The position after the blanks that start at `at`."
  @spec skip_ws(ctx(), non_neg_integer()) :: non_neg_integer()
  def skip_ws(ctx, at), do: if(ws?(ctx, at), do: skip_ws(ctx, at + 1), else: at)

  @doc """
  The word at `at` (letters, digits, underscore) in lower case, and where it
  ends.
  """
  @spec word_at(ctx(), non_neg_integer()) :: {binary(), non_neg_integer()} | nil
  def word_at(ctx, at) when at < ctx.size do
    case Regex.run(~r/^[A-Za-z_][A-Za-z0-9_]*/, binary_part(ctx.masked, at, ctx.size - at)) do
      [word] -> {String.downcase(word), at + byte_size(word)}
      nil -> nil
    end
  end

  def word_at(_ctx, _at), do: nil

  @doc """
  A clause keyword after a blank: `{:ok, at}` where the word starts, `:none`
  when the clause is not there (a longer word is another word).
  """
  @spec keyword(ctx(), non_neg_integer(), binary()) :: {:ok, non_neg_integer()} | :none
  def keyword(ctx, pos, name) do
    with true <- ws?(ctx, pos) || :none,
         at = skip_ws(ctx, pos),
         {^name, _to} <- word_at(ctx, at) || :none do
      {:ok, at}
    else
      _other -> :none
    end
  end

  # What may stand directly against a SHOW keyword for the engine to read it: a blank, the
  # end of the statement, a `;`, or one of the characters of an operator or a parenthesis
  # (`SHOW TAG KEYS(` is left over from the `(`). Any other character (a form feed, a vertical
  # tab, a carriage return, a quote, a dot, `#`, `$`, a control character, a byte of a
  # non-ASCII character) leaves the word unread, as if it were another word: verified for each
  # ASCII character after `SHOW TAG KEYS`, and for U+00A0 and the control characters after the
  # kinds and the clause words.
  @keyword_end [nil, " ", "\t", "\n", ";" | InfluxQLText.operator_glue()]

  @doc "Whether a keyword that ends at `at` is read as one (see the table above)."
  @spec keyword_end?(ctx(), non_neg_integer()) :: boolean()
  def keyword_end?(ctx, at), do: at_byte(ctx, at) in @keyword_end

  @doc "The keyword `name` at `at`: `{:ok, end of the word}` or `:no`."
  @spec keyword_here(ctx(), non_neg_integer(), binary()) :: {:ok, non_neg_integer()} | :no
  def keyword_here(ctx, at, name) do
    case word_at(ctx, at) do
      {^name, to} -> if keyword_end?(ctx, to), do: {:ok, to}, else: :no
      _other -> :no
    end
  end

  @doc "The spec with `item` added to what the engine raises when it plans the statement."
  @spec defer(map(), term()) :: map()
  def defer(spec, item), do: %{spec | deferred: [item | spec.deferred]}

  # ---- a name -----------------------------------------------------------------

  @doc """
  A bare name (not a reserved word) or a quoted one, as `{:ok, name, to}`;
  `:none` for anything else.
  """
  @spec name_at(ctx(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | :none | {:error, term()}
  def name_at(ctx, at) do
    case at_byte(ctx, at) do
      "\"" -> quoted_name(ctx, at)
      nil -> :none
      byte -> if byte =~ ~r/[A-Za-z_]/, do: bare_name(ctx, at), else: :none
    end
  end

  defp bare_name(ctx, at) do
    [word] = Regex.run(~r/^[A-Za-z_][A-Za-z0-9_]*/, binary_part(ctx.clean, at, ctx.size - at))
    if InfluxQLText.reserved?(word), do: :none, else: {:ok, word, at + byte_size(word)}
  end

  # A quoted name never closed is the lexer's error at the end of the text: the parser meets
  # it only here, where it reads a name (verified: after a keyword or in a clause that wants
  # something else the quote is no token, see `lexer_error/2`).
  defp quoted_name(ctx, at) do
    case :binary.match(ctx.masked, "\"", scope: {at + 1, ctx.size - at - 1}) do
      {close, 1} ->
        inside = binary_part(ctx.clean, at + 1, close - at - 1)

        case unescape(inside, at + 1, []) do
          {:ok, name} -> {:ok, name, close + 1}
          {:bad, pos} -> error("invalid escape sequence, expected \\\\, \\\" or \\n", pos)
        end

      :nomatch ->
        {:error,
         {:engine, InfluxQLError.syntax_error_body(:unterminated_string, ctx.size, ctx.raw)}}
    end
  end

  @doc """
  The lexer's error for a string, quoted name or regular expression never closed that starts
  at or after `from`, `nil` when there is none. The parser meets it only where it reads a
  token there: in an expression (a `WHERE`), a name or a regular expression. Anywhere else the
  quote is what the clause fails at (verified: `LIMIT 'x`, `ON 'x`, `SHOW 'x`, `m 'x`).
  """
  @spec lexer_error(ctx(), non_neg_integer()) :: {:error, {:engine, binary()}} | nil
  def lexer_error(%{bad: {kind, start}} = ctx, from) when start >= from,
    do: {:error, {:engine, InfluxQLError.syntax_error_body(kind, ctx.size, ctx.raw)}}

  def lexer_error(_ctx, _from), do: nil

  defp unescape(<<>>, _at, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp unescape(<<?\\, ?\\, rest::binary>>, at, acc), do: unescape(rest, at + 2, ["\\" | acc])
  defp unescape(<<?\\, ?", rest::binary>>, at, acc), do: unescape(rest, at + 2, ["\"" | acc])
  defp unescape(<<?\\, ?n, rest::binary>>, at, acc), do: unescape(rest, at + 2, ["\n" | acc])
  defp unescape(<<?\\, _other, _rest::binary>>, at, _acc), do: {:bad, at + 1}
  defp unescape(<<c, rest::binary>>, at, acc), do: unescape(rest, at + 1, [<<c>> | acc])

  # ---- a list of sources --------------------------------------------------------

  @doc """
  The measurements of a `FROM` list: names and regular expressions (and the
  qualified names the engine does not implement), or `:none` when the first is
  none.
  """
  @spec sources(ctx(), non_neg_integer()) ::
          {:ok, [term()], non_neg_integer()} | :none | {:error, binary()}
  def sources(ctx, at) do
    case source_at(ctx, at) do
      {:ok, item, to} -> more_sources(ctx, to, [item])
      other -> other
    end
  end

  # A comma that no source follows is not part of the list: the statement is
  # left from it.
  @spec more_sources(ctx(), non_neg_integer(), [term()]) ::
          {:ok, [term()], non_neg_integer()} | {:error, binary()}
  defp more_sources(ctx, to, acc) do
    comma = skip_ws(ctx, to)

    with true <- at_byte(ctx, comma) == ",",
         {:ok, item, after_item} <- source_at(ctx, skip_ws(ctx, comma + 1)) do
      more_sources(ctx, after_item, [item | acc])
    else
      {:error, _reason} = error -> error
      _end_of_list -> {:ok, Enum.reverse(acc), to}
    end
  end

  @doc """
  A regular expression, or a name that may be qualified: `a.b` names a
  retention policy, `a.b.c` and `a..b` a database, which the engine does not
  implement in a measurement list (a 405 after the statement parsed).
  """
  @spec source_at(ctx(), non_neg_integer()) ::
          {:ok, term(), non_neg_integer()} | :none | {:error, binary()}
  def source_at(ctx, at) do
    if at_byte(ctx, at) == "/" do
      regex_at(ctx, at)
    else
      with {:ok, name, to} <- name_at(ctx, at) do
        if at_byte(ctx, to) == ".", do: qualifiers(ctx, to, 1), else: {:ok, {:name, name}, to}
      end
    end
  end

  defp qualifiers(ctx, at, parts) do
    cond do
      at_byte(ctx, at) != "." ->
        {:ok, {:unavailable, qualifier_message(parts)}, at}

      at_byte(ctx, at + 1) == "." ->
        qualifiers(ctx, at + 1, parts + 1)

      true ->
        case name_at(ctx, at + 1) do
          {:ok, _name, to} -> qualifiers(ctx, to, parts + 1)
          {:error, _reason} = error -> error
          :none -> {:error, "unsupported InfluxQL (a qualified name that does not end in a name)"}
        end
    end
  end

  defp qualifier_message(2), do: "retention policy in from clause"
  defp qualifier_message(_parts), do: "database name in from clause"

  @doc "The regular expression at `at`, compiled: `{:ok, {:regex, regex}, to}`."
  @spec regex_at(ctx(), non_neg_integer()) ::
          {:ok, term(), non_neg_integer()} | {:error, binary()}
  def regex_at(ctx, at) do
    with {:ok, source, to} <- regex_literal(ctx, at) do
      {:ok, {:regex, InfluxQLRegex.compile(source)}, to}
    end
  catch
    {:refused, message} when is_binary(message) ->
      {:error, message}

    {:refused, {:engine, _status, _body}} ->
      {:error, "unsupported InfluxQL (that regular expression)"}
  end

  @doc """
  The text of the `/re/` at `at` as the engine reads it (`\\/` is a slash), and
  where it ends; the lexer's error for one never closed.
  """
  @spec regex_literal(ctx(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, {:engine, binary()}}
  def regex_literal(ctx, at) do
    case :binary.match(ctx.masked, "/", scope: {at + 1, ctx.size - at - 1}) do
      {close, 1} ->
        inside = binary_part(ctx.clean, at + 1, close - at - 1)
        {:ok, String.replace(inside, "\\/", "/"), close + 1}

      :nomatch ->
        {:error,
         {:engine, InfluxQLError.syntax_error_body(:unterminated_regex, ctx.size, ctx.raw)}}
    end
  end
end
