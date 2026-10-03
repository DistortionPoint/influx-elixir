defmodule InfluxElixir.Client.Local.InfluxQLShowParser do
  @moduledoc false
  # Reads an InfluxQL `SHOW` statement as the engine's parser does (verified
  # clause by clause against InfluxDB 3 Core): the kind (`DATABASES`,
  # `RETENTION POLICIES`, `MEASUREMENTS`, `TAG KEYS`, `TAG VALUES`,
  # `FIELD KEYS`) and its clauses in the engine's order, each with the parse
  # error and the position the engine gives it.
  #
  # The statement is scanned once: comments become blanks and the inside of
  # every string, quoted name and regular expression is masked, byte for
  # byte, so a keyword inside a literal is no keyword and every position is
  # the engine's. The text an error shows is the statement as sent.
  #
  # What the double does not read as the engine does is refused by name,
  # never given another body: a regular expression the double's engine cannot
  # compile, a name qualified in a way not verified, a `WHERE` the engine
  # stops reading half way, a second statement after `;` that is neither a
  # `SHOW` nor text the engine cannot read.

  alias InfluxElixir.Client.Local.{InfluxQLError, InfluxQLShowClauses, InfluxQLShowText}

  import InfluxElixir.Client.Local.InfluxQLShowText,
    only: [at_byte: 2, error: 2, rest: 2, skip_ws: 2, word_at: 2, ws?: 2]

  @type source :: {:name, binary()} | {:regex, Regex.t()}

  @type spec :: %{
          kind: :databases | :retention | :measurements | :tag_keys | :field_keys | :tag_values,
          on: binary() | nil,
          from: [source()] | nil,
          measurement: source() | nil,
          keys: InfluxElixir.Client.Local.InfluxQL.key_filter() | nil,
          where: binary() | nil,
          limit: non_neg_integer() | nil,
          offset: non_neg_integer()
        }

  @type ctx :: InfluxQLShowText.ctx()

  @generic "invalid SHOW statement, expected DATABASES, FIELD KEYS, MEASUREMENTS, " <>
             "TAG KEYS, TAG VALUES, or RETENTION POLICIES following SHOW"
  @only_one "must provide only one InfluxQl statement per query"
  @kinds ~w(databases retention measurements tag field)

  @show_word ~r/^\s*show(?![A-Za-z0-9_])/i

  @clauses %{
    databases: [],
    retention: [:on],
    measurements: [:on_wild, :with_measurement, :where, :limit, :offset],
    tag_keys: [:on, :from, :where, :limit, :offset],
    field_keys: [:on, :from, :limit, :offset],
    tag_values: [:on, :from, :with_key, :where, :limit, :offset]
  }

  @doc """
  Parses a `SHOW` statement as sent: `nil` when the text is not one, else the
  spec (its `planning` is the error the engine raises when it plans the
  statement, `nil` if none), the engine's parse error (`{:engine, body}`) or
  the refusal (a message the caller frames).
  """
  @spec parse(binary()) :: nil | {:ok, map()} | {:error, binary() | {:engine, binary()}}
  def parse(raw) do
    if Regex.match?(@show_word, raw), do: read(raw)
  end

  @spec read(binary()) :: nil | {:ok, map()} | {:error, term()}
  defp read(raw) do
    scanned = scan(raw)
    ctx = %{raw: raw, clean: scanned.clean, masked: scanned.masked, size: byte_size(raw)}

    with after_show when after_show != nil <- start(ctx),
         :ok <- scanned_error(scanned, ctx) do
      statement(ctx, after_show)
    end
  end

  @spec scanned_error(map(), ctx()) :: :ok | {:error, {:engine, binary()}}
  defp scanned_error(%{unclosed: at}, ctx) when is_integer(at),
    do: {:error, {:engine, InfluxQLError.syntax_error_body(:comment, at, ctx.raw)}}

  defp scanned_error(%{bad: kind}, ctx) when kind != nil,
    do: {:error, {:engine, InfluxQLError.syntax_error_body(kind, ctx.size, ctx.raw)}}

  defp scanned_error(_scanned, _ctx), do: :ok

  # ---------------------------------------------------------------------------
  # Scanning
  # ---------------------------------------------------------------------------

  @spec scan(binary()) :: map()
  defp scan(raw) do
    state = %{clean: [], masked: [], unclosed: nil, bad: nil}
    state = walk(raw, 0, false, state)

    %{
      state
      | clean: state.clean |> Enum.reverse() |> IO.iodata_to_binary(),
        masked: state.masked |> Enum.reverse() |> IO.iodata_to_binary()
    }
  end

  # `regex?` says a `/` starts a regular expression here: after `=~`, `!~`,
  # `FROM` and a comma.
  @spec walk(binary(), non_neg_integer(), boolean(), map()) :: map()
  defp walk(<<>>, _at, _regex?, state), do: state

  defp walk(<<"--", _rest::binary>> = text, at, regex?, state) do
    [comment] = Regex.run(~r/^--[^\n]*/, text)
    skip_comment(text, comment, at, regex?, state)
  end

  defp walk(<<"/*", _rest::binary>> = text, at, regex?, state) do
    [comment] = Regex.run(~r/^\/\*.*?\*\/|^\/\*.*/s, text)

    state =
      if String.ends_with?(comment, "*/") and byte_size(comment) >= 4,
        do: state,
        else: %{state | unclosed: at + 2}

    skip_comment(text, comment, at, regex?, state)
  end

  defp walk(<<quote, rest::binary>>, at, _regex?, state) when quote in [?', ?"] do
    literal(rest, quote, at + 1, [<<quote>>], state, :unterminated_string)
  end

  defp walk(<<?/, rest::binary>>, at, true, state),
    do: literal(rest, ?/, at + 1, ["/"], state, :unterminated_regex)

  defp walk(<<op::binary-size(2), rest::binary>>, at, _regex?, state) when op in ["=~", "!~"],
    do: walk(rest, at + 2, true, put(state, op, op))

  defp walk(<<c, rest::binary>>, at, regex?, state) when c in [?\s, ?\t, ?\n, ?\r],
    do: walk(rest, at + 1, regex?, put(state, <<c>>, <<c>>))

  defp walk(<<?,, rest::binary>>, at, _regex?, state),
    do: walk(rest, at + 1, true, put(state, ",", ","))

  defp walk(<<c, _rest::binary>> = text, at, _regex?, state)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    [word] = Regex.run(~r/^[A-Za-z_][A-Za-z0-9_]*/, text)
    rest = binary_part(text, byte_size(word), byte_size(text) - byte_size(word))
    walk(rest, at + byte_size(word), String.downcase(word) == "from", put(state, word, word))
  end

  defp walk(<<c, rest::binary>>, at, _regex?, state),
    do: walk(rest, at + 1, false, put(state, <<c>>, <<c>>))

  @spec skip_comment(binary(), binary(), non_neg_integer(), boolean(), map()) :: map()
  defp skip_comment(text, comment, at, regex?, state) do
    size = byte_size(comment)
    blank = String.duplicate(" ", size)
    rest = binary_part(text, size, byte_size(text) - size)
    walk(rest, at + size, regex?, put(state, blank, blank))
  end

  @spec put(map(), iodata(), iodata()) :: map()
  defp put(state, clean, masked),
    do: %{state | clean: [clean | state.clean], masked: [masked | state.masked]}

  # A string, quoted name or regular expression up to its closing delimiter.
  # A backslash escapes the byte after it inside a string or a quoted name,
  # only `\/` inside a regular expression. The inside is masked with `_`.
  @spec literal(binary(), byte(), non_neg_integer(), iodata(), map(), atom()) :: map()
  defp literal(<<>>, _closing, _at, taken, state, kind) do
    inside = taken |> Enum.reverse() |> IO.iodata_to_binary()
    opening = binary_part(inside, 0, 1)
    body = binary_part(inside, 1, byte_size(inside) - 1)
    state = put(state, inside, opening <> String.duplicate("_", byte_size(body)))
    %{state | bad: state.bad || kind}
  end

  defp literal(<<?\\, ?/, rest::binary>>, ?/, at, taken, state, kind),
    do: literal(rest, ?/, at + 2, ["/", "\\" | taken], state, kind)

  defp literal(<<?\\, c, rest::binary>>, closing, at, taken, state, kind) when closing != ?/,
    do: literal(rest, closing, at + 2, [<<c>>, "\\" | taken], state, kind)

  defp literal(<<closing, rest::binary>>, closing, at, taken, state, _kind) do
    inside = [<<closing>> | taken] |> Enum.reverse() |> IO.iodata_to_binary()
    body = binary_part(inside, 1, byte_size(inside) - 2)
    opening = binary_part(inside, 0, 1)
    masked = opening <> String.duplicate("_", byte_size(body)) <> <<closing>>
    walk(rest, at + 1, false, put(state, inside, masked))
  end

  defp literal(<<c, rest::binary>>, closing, at, taken, state, kind),
    do: literal(rest, closing, at + 1, [<<c>> | taken], state, kind)

  # ---------------------------------------------------------------------------
  # The statement
  # ---------------------------------------------------------------------------

  # The offset after a leading `SHOW`, or `nil` when the text is no SHOW.
  @spec start(ctx()) :: non_neg_integer() | nil
  defp start(ctx) do
    case word_at(ctx, skip_ws(ctx, 0)) do
      {"show", at} -> at
      _other -> nil
    end
  end

  @spec statement(ctx(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  defp statement(ctx, after_show) do
    cond do
      rest(ctx, after_show) in ["", ";"] -> many1(ctx, after_show)
      ws?(ctx, after_show) -> kind(ctx, skip_ws(ctx, after_show))
      true -> {:error, "unsupported InfluxQL (SHOW followed by that)"}
    end
  end

  # `SHOW` and nothing after it: the statement list fails where it starts,
  # showing what follows `SHOW`.
  @spec many1(ctx(), non_neg_integer()) :: {:error, term()}
  defp many1(ctx, after_show) do
    if skip_ws(ctx, 0) == 0 do
      {:error,
       {:engine,
        InfluxQLShowText.prefix() <>
          "invalid InfluxQL statement at pos 0. " <>
          "Parsing Error: Nom(#{inspect(rest(ctx, after_show))}, Many1)"}}
    else
      {:error, "unsupported InfluxQL (SHOW with blanks before it and nothing after)"}
    end
  end

  @spec kind(ctx(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  defp kind(ctx, at) do
    case word_at(ctx, at) do
      {word, to} when word in @kinds -> kind(ctx, at, word, to)
      {_word, _to} -> error(@generic, at)
      nil -> error(@generic, at)
    end
  end

  defp kind(ctx, _at, "databases", to), do: clauses(ctx, to, new(:databases))
  defp kind(ctx, _at, "measurements", to), do: clauses(ctx, to, new(:measurements))

  defp kind(ctx, at, "retention", to),
    do:
      sub(ctx, at, to, "invalid SHOW RETENTION POLICIES statement, expected POLICIES", %{
        "policies" => :retention
      })

  defp kind(ctx, at, "tag", to),
    do:
      sub(ctx, at, to, "invalid SHOW TAG statement, expected KEYS or VALUES", %{
        "keys" => :tag_keys,
        "values" => :tag_values
      })

  defp kind(ctx, at, "field", to),
    do:
      sub(ctx, at, to, "invalid SHOW FIELD KEYS statement, expected KEYS", %{
        "keys" => :field_keys
      })

  # `SHOW TAG KEYS`: the second word after a blank, or the engine's error
  # where that word stands. Without a blank the first word does not match and
  # the statement is none of the kinds.
  @spec sub(ctx(), non_neg_integer(), non_neg_integer(), binary(), map()) ::
          {:ok, map()} | {:error, term()}
  defp sub(ctx, at, to, message, words) do
    if ws?(ctx, to) do
      second = skip_ws(ctx, to)

      case word_at(ctx, second) do
        {word, after_word} when is_map_key(words, word) ->
          clauses(ctx, after_word, new(Map.fetch!(words, word)))

        _other ->
          error(message, second)
      end
    else
      error(@generic, at)
    end
  end

  @spec new(atom()) :: map()
  defp new(kind) do
    %{
      kind: kind,
      on: nil,
      from: nil,
      measurement: nil,
      keys: nil,
      where: nil,
      limit: nil,
      offset: 0,
      deferred: []
    }
  end

  # ---------------------------------------------------------------------------
  # Clauses
  # ---------------------------------------------------------------------------

  @spec clauses(ctx(), non_neg_integer(), map()) :: {:ok, map()} | {:error, term()}
  defp clauses(ctx, pos, spec), do: run(ctx, pos, Map.fetch!(@clauses, spec.kind), spec)

  defp run(ctx, pos, [], spec), do: finish(ctx, pos, spec)

  defp run(ctx, pos, [name | more], spec) do
    case InfluxQLShowClauses.clause(name, ctx, pos, spec) do
      {:ok, spec, pos} -> run(ctx, pos, more, spec)
      :none -> run(ctx, pos, more, spec)
      {:error, _reason} = error -> error
    end
  end

  # ---- the end ----------------------------------------------------------------------

  @spec finish(ctx(), non_neg_integer(), map()) :: {:ok, map()} | {:error, term()}
  defp finish(ctx, pos, spec) do
    at = skip_ws(ctx, pos)

    cond do
      at == ctx.size -> planned(spec)
      at_byte(ctx, at) == ";" -> after_semicolon(ctx, at + 1, spec)
      true -> {:error, {:engine, InfluxQLError.syntax_error_body(:nom, at, ctx.raw)}}
    end
  end

  # The engine takes one statement per query: a second that reads is its 400,
  # one that does not is its own parse error.
  defp after_semicolon(ctx, from, spec) do
    next = skip_blanks_and_semicolons(ctx, from)

    if next == ctx.size do
      planned(spec)
    else
      text = binary_part(ctx.raw, next, ctx.size - next)

      case parse(text) do
        {:ok, _spec} ->
          {:error, {:engine, @only_one}}

        {:error, {:engine, body}} ->
          {:error, {:engine, InfluxQLError.shift_position(body, next)}}

        {:error, "unsupported" <> _rest} = refusal ->
          refusal

        _unread ->
          second_statement(ctx, text, next)
      end
    end
  end

  # Text after the `;` that is no statement the double reads: if it does not
  # start like one the engine reads, it fails where it starts.
  defp second_statement(ctx, text, next) do
    if Regex.match?(~r/^(?:SELECT|SHOW|EXPLAIN|CREATE|DELETE|DROP)(?![\w])/i, text),
      do: {:error, "unsupported InfluxQL (a second statement after `;`)"},
      else: {:error, {:engine, InfluxQLError.syntax_error_body(:nom, next, ctx.raw)}}
  end

  defp skip_blanks_and_semicolons(ctx, at) do
    at = skip_ws(ctx, at)
    if at_byte(ctx, at) == ";", do: skip_blanks_and_semicolons(ctx, at + 1), else: at
  end

  # What the engine raises once the statement parsed: `ON *` at once, the rest
  # (`planning`) when it plans the statement, which is after it has found the
  # database.
  @spec planned(map()) :: {:ok, map()} | {:error, {:engine, binary()}}
  defp planned(%{deferred: deferred} = spec) do
    deferred = Enum.reverse(deferred)

    case Enum.find(deferred, &match?({:statement, _message}, &1)) do
      {:statement, message} ->
        {:error, {:engine, "error in InfluxQL statement: " <> message}}

      nil ->
        {:ok, spec |> Map.delete(:deferred) |> Map.put(:planning, planning(deferred))}
    end
  end

  @spec planning([term()]) :: nil | {:engine, binary()} | {:engine, pos_integer(), binary()}
  defp planning([]), do: nil

  defp planning([{:planning, message} | _rest]),
    do: {:engine, "Error during planning: " <> message}

  defp planning([{:not_implemented, message} | _rest]),
    do: {:engine, 405, "This feature is not implemented: " <> message}
end
