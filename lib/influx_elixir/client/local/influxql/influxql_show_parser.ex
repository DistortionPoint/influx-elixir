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

  alias InfluxElixir.Client.Local.{
    InfluxQLCheck,
    InfluxQLError,
    InfluxQLRegex,
    InfluxQLText,
    InfluxQLTokens
  }

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

  @type ctx :: %{
          raw: binary(),
          clean: binary(),
          masked: binary(),
          size: non_neg_integer()
        }

  @prefix "error in InfluxQL statement: parsing error: "
  @generic "invalid SHOW statement, expected DATABASES, FIELD KEYS, MEASUREMENTS, " <>
             "TAG KEYS, TAG VALUES, or RETENTION POLICIES following SHOW"
  @only_one "must provide only one InfluxQl statement per query"
  @uint64_max 18_446_744_073_709_551_615
  @kinds ~w(databases retention measurements tag field)
  @cond_end ~r/\b(?:LIMIT|OFFSET|SLIMIT|SOFFSET|GROUP|ORDER|FILL)\b|;/i

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
        @prefix <>
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
    case clause(name, ctx, pos, spec) do
      {:ok, spec, pos} -> run(ctx, pos, more, spec)
      :none -> run(ctx, pos, more, spec)
      {:error, _reason} = error -> error
    end
  end

  # `ON db`: past `ON` the engine wants a blank and a name; without them it is
  # its error at the end of `ON`.
  defp clause(:on, ctx, pos, spec) do
    with {:ok, at} <- keyword(ctx, pos, "on"),
         to = at + 2,
         true <- at_byte(ctx, to) not in ["\"", "."] || :none do
      case ws?(ctx, to) and name_at(ctx, skip_ws(ctx, to)) do
        {:ok, name, after_name} -> {:ok, %{spec | on: name}, after_name}
        {:error, _reason} = error -> error
        _no_name -> error("invalid ON clause, expected identifier", to)
      end
    end
  end

  # `SHOW MEASUREMENTS ON`: a name or a wildcard, after a blank.
  defp clause(:on_wild, ctx, pos, spec) do
    with {:ok, at} <- keyword(ctx, pos, "on"),
         true <- ws?(ctx, at + 2) || :none do
      first = skip_ws(ctx, at + 2)

      case name_at(ctx, first) do
        {:ok, name, after_name} -> qualified_database(ctx, first, name, after_name, spec)
        {:error, _reason} = error -> error
        :none -> wildcard(ctx, first, spec)
      end
    end
  end

  defp clause(:from, ctx, pos, spec) do
    with {:ok, at} <- keyword(ctx, pos, "from"),
         true <- ws?(ctx, at + 4) || :none do
      first = skip_ws(ctx, at + 4)

      case sources(ctx, first) do
        {:ok, items, to} -> {:ok, from_items(spec, items), to}
        :none -> error("invalid FROM clause, expected identifier or regular expression", first)
        {:error, _reason} = error -> error
      end
    end
  end

  defp clause(:with_measurement, ctx, pos, spec) do
    with {:ok, at} <- keyword(ctx, pos, "with"),
         true <- ws?(ctx, at + 4) || :none do
      word = skip_ws(ctx, at + 4)

      case keyword_here(ctx, word, "measurement") do
        {:ok, to} -> measurement_operator(ctx, to, spec)
        :no -> error("invalid WITH clause, expected MEASUREMENT", word)
      end
    end
  end

  defp clause(:where, ctx, pos, spec) do
    with {:ok, at} <- keyword(ctx, pos, "where"),
         true <- ws?(ctx, at + 5) || :none do
      from = skip_ws(ctx, at + 5)
      to = condition_end(ctx, from)
      text = ctx.clean |> binary_part(from, to - from) |> String.trim_trailing()

      if text == "", do: :none, else: condition(ctx, text, from + byte_size(text), spec)
    end
  end

  defp clause(:limit, ctx, pos, spec), do: count(ctx, pos, "limit", :limit, spec)
  defp clause(:offset, ctx, pos, spec), do: count(ctx, pos, "offset", :offset, spec)

  # `WITH KEY` is required; each way it fails is the engine's error at the
  # place it names (the end of the word before it, or past the blank).
  defp clause(:with_key, ctx, pos, spec) do
    with true <- ws?(ctx, pos),
         at = skip_ws(ctx, pos),
         {:ok, to} <- keyword_here(ctx, at, "with"),
         true <- ws?(ctx, to) do
      word = skip_ws(ctx, to)

      case keyword_here(ctx, word, "key") do
        {:ok, after_key} -> key_condition(ctx, after_key, spec)
        :no -> error("invalid WITH KEY clause, expected KEY", word)
      end
    else
      _absent -> error("invalid SHOW TAG VALUES statement, expected WITH KEY clause", pos)
    end
  end

  # A clause keyword after a blank: `{:ok, at}` where the word starts, `:none`
  # when the clause is not there (a longer word is another word).
  @spec keyword(ctx(), non_neg_integer(), binary()) :: {:ok, non_neg_integer()} | :none
  defp keyword(ctx, pos, name) do
    with true <- ws?(ctx, pos) || :none,
         at = skip_ws(ctx, pos),
         {^name, _to} <- word_at(ctx, at) || :none do
      {:ok, at}
    else
      _other -> :none
    end
  end

  @spec keyword_here(ctx(), non_neg_integer(), binary()) :: {:ok, non_neg_integer()} | :no
  defp keyword_here(ctx, at, name) do
    case word_at(ctx, at) do
      {^name, to} -> {:ok, to}
      _other -> :no
    end
  end

  # `db.rp` names the database `db/rp`, except for the policy `autogen`, which
  # is `db` itself (verified); `db.` and `db.*` fail where the name starts.
  @spec qualified_database(ctx(), non_neg_integer(), binary(), non_neg_integer(), map()) ::
          {:ok, map(), non_neg_integer()} | {:error, term()}
  defp qualified_database(ctx, first, name, after_name, spec) do
    if at_byte(ctx, after_name) == "." do
      case name_at(ctx, after_name + 1) do
        {:ok, "autogen", to} -> {:ok, %{spec | on: name}, to}
        {:ok, policy, to} -> {:ok, %{spec | on: name <> "/" <> policy}, to}
        _no_policy -> error("invalid ON clause, expected wildcard or identifier", first)
      end
    else
      {:ok, %{spec | on: name}, after_name}
    end
  end

  # `ON *` reads, and the engine refuses it when it plans the statement.
  defp wildcard(ctx, at, spec) do
    if at_byte(ctx, at) == "*",
      do:
        {:ok, defer(spec, {:statement, "can only perform queries on a single database"}), at + 1},
      else: error("invalid ON clause, expected wildcard or identifier", at)
  end

  # ---- FROM -----------------------------------------------------------------

  @spec sources(ctx(), non_neg_integer()) ::
          {:ok, [term()], non_neg_integer()} | :none | {:error, binary()}
  defp sources(ctx, at) do
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

  # A regular expression, or a name that may be qualified: `a.b` names a
  # retention policy, `a.b.c` and `a..b` a database, which the engine does not
  # implement in a measurement list (a 405 after the statement parsed).
  @spec source_at(ctx(), non_neg_integer()) ::
          {:ok, term(), non_neg_integer()} | :none | {:error, binary()}
  defp source_at(ctx, at) do
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

  @spec regex_at(ctx(), non_neg_integer()) ::
          {:ok, term(), non_neg_integer()} | {:error, binary()}
  defp regex_at(ctx, at) do
    {source, to} = regex_literal(ctx, at)

    {:ok, {:regex, InfluxQLRegex.compile(source)}, to}
  catch
    {:refused, message} when is_binary(message) ->
      {:error, message}

    {:refused, {:engine, _status, _body}} ->
      {:error, "unsupported InfluxQL (that regular expression)"}
  end

  # The text of the `/re/` at `at` as the engine reads it (`\/` is a slash),
  # and where it ends.
  @spec regex_literal(ctx(), non_neg_integer()) :: {binary(), non_neg_integer()}
  defp regex_literal(ctx, at) do
    {close, 1} = :binary.match(ctx.masked, "/", scope: {at + 1, ctx.size - at - 1})
    inside = binary_part(ctx.clean, at + 1, close - at - 1)
    {String.replace(inside, "\\/", "/"), close + 1}
  end

  # ---- a name -----------------------------------------------------------------

  # A bare name (not a reserved word) or a quoted one, as `{:ok, name, to}`;
  # `:none` for anything else.
  @spec name_at(ctx(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | :none | {:error, term()}
  defp name_at(ctx, at) do
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

  defp quoted_name(ctx, at) do
    {close, 1} = :binary.match(ctx.masked, "\"", scope: {at + 1, ctx.size - at - 1})
    inside = binary_part(ctx.clean, at + 1, close - at - 1)

    case unescape(inside, at + 1, []) do
      {:ok, name} -> {:ok, name, close + 1}
      {:bad, pos} -> error("invalid escape sequence, expected \\\\, \\\" or \\n", pos)
    end
  end

  defp unescape(<<>>, _at, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp unescape(<<?\\, ?\\, rest::binary>>, at, acc), do: unescape(rest, at + 2, ["\\" | acc])
  defp unescape(<<?\\, ?", rest::binary>>, at, acc), do: unescape(rest, at + 2, ["\"" | acc])
  defp unescape(<<?\\, ?n, rest::binary>>, at, acc), do: unescape(rest, at + 2, ["\n" | acc])
  defp unescape(<<?\\, _other, _rest::binary>>, at, _acc), do: {:bad, at + 1}
  defp unescape(<<c, rest::binary>>, at, acc), do: unescape(rest, at + 1, [<<c>> | acc])

  # ---- WITH MEASUREMENT ---------------------------------------------------------

  defp measurement_operator(ctx, to, spec) do
    op = skip_ws(ctx, to)

    cond do
      rest_starts?(ctx, op, "=~") -> measurement_regex(ctx, op, spec)
      rest_starts?(ctx, op, "=") -> measurement_name(ctx, skip_ws(ctx, op + 1), spec)
      true -> error("expected = or =~", op)
    end
  end

  # After `=` the engine wants a name; a regular expression is its planning
  # error.
  defp measurement_name(ctx, at, spec) do
    if at_byte(ctx, at) == "/" do
      {_source, to} = regex_literal(ctx, at)
      {:ok, defer(spec, {:planning, "expected string but got regex"}), to}
    else
      case source_at(ctx, at) do
        {:ok, item, to} -> {:ok, put_measurement(spec, item), to}
        :none -> error("expected measurement name", at)
        {:error, _reason} = error -> error
      end
    end
  end

  # After `=~` the engine wants a regular expression; a name is its planning
  # error.
  defp measurement_regex(ctx, op, spec) do
    at = skip_ws(ctx, op + 2)

    if at_byte(ctx, at) == "/" do
      with {:ok, item, to} <- regex_at(ctx, at), do: {:ok, put_measurement(spec, item), to}
    else
      case name_at(ctx, at) do
        {:ok, _name, to} -> {:ok, defer(spec, {:planning, "expected regex but got string"}), to}
        :none -> error("expected measurement name", op + 1)
        {:error, _reason} = error -> error
      end
    end
  end

  defp put_measurement(spec, {:unavailable, message}),
    do: defer(spec, {:not_implemented, message})

  defp put_measurement(spec, item), do: %{spec | measurement: item}

  # ---- WHERE ------------------------------------------------------------------

  # The condition ends at the clause word (or `;`) that follows it.
  @spec condition_end(ctx(), non_neg_integer()) :: non_neg_integer()
  defp condition_end(ctx, from) do
    tail = binary_part(ctx.masked, from, ctx.size - from)

    case Regex.run(@cond_end, tail, return: :index) do
      [{at, _size}] -> from + at
      nil -> ctx.size
    end
  end

  defp condition(ctx, text, to, spec) do
    case InfluxQLCheck.check_where(ctx.raw, 0, ctx.masked, text) do
      :ok -> read_condition(text, to, spec)
      {:error, _engine} = error -> error
    end
  end

  # Operands side by side are a condition the engine stops reading half way.
  defp read_condition(text, to, spec) do
    case InfluxQLTokens.tokenize(text, []) do
      {:ok, tokens} ->
        if adjacent_operands?(tokens),
          do: {:error, "unsupported InfluxQL (a WHERE the double does not read to its end)"},
          else: {:ok, %{spec | where: text}, to}

      _unread ->
        {:ok, %{spec | where: text}, to}
    end
  end

  defp adjacent_operands?(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [left, right] -> operand?(left) and operand?(right) end)
  end

  defp operand?({kind, _value}) when kind in [:ident, :str, :number], do: true
  defp operand?({:duration, _total, _text}), do: true
  defp operand?(_token), do: false

  # ---- LIMIT and OFFSET -----------------------------------------------------------

  defp count(ctx, pos, name, field, spec) do
    with {:ok, at} <- keyword(ctx, pos, name),
         true <- ws?(ctx, at + byte_size(name)) || :none do
      from = skip_ws(ctx, at + byte_size(name))

      case Regex.run(~r/^\d+/, binary_part(ctx.masked, from, ctx.size - from)) do
        [digits] -> number(digits, from, field, ctx, spec)
        nil -> {:error, {:engine, InfluxQLError.syntax_error_body(field, from, ctx.raw)}}
      end
    end
  end

  defp number(digits, from, field, ctx, spec) do
    value = String.to_integer(digits)
    to = from + byte_size(digits)

    cond do
      value > @uint64_max ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:unsigned, to, ctx.raw)}}

      # The largest LIMIT with an OFFSET after it keeps nothing (verified).
      field == :offset and value > 0 and spec.limit == @uint64_max and
          spec.kind != :measurements ->
        {:error, "unsupported InfluxQL (the largest LIMIT with an OFFSET)"}

      true ->
        {:ok, Map.put(spec, field, value), to}
    end
  end

  # ---- WITH KEY ---------------------------------------------------------------------

  defp key_condition(ctx, after_key, spec) do
    op = skip_ws(ctx, after_key)

    cond do
      rest_starts?(ctx, op, "=~") -> key_regex(ctx, op + 2, true, spec)
      rest_starts?(ctx, op, "!~") -> key_regex(ctx, op + 2, false, spec)
      rest_starts?(ctx, op, "!=") -> key_name(ctx, op + 2, :ne, spec)
      rest_starts?(ctx, op, "=") -> key_name(ctx, op + 1, :eq, spec)
      rest_starts?(ctx, op, "IN") -> key_list(ctx, op + 2, spec)
      true -> error("invalid WITH KEY clause, expected condition", after_key)
    end
  end

  defp key_regex(ctx, after_op, match?, spec) do
    at = skip_ws(ctx, after_op)

    cond do
      at_byte(ctx, at) == "/" ->
        with {:ok, {:regex, regex}, to} <- regex_at(ctx, at),
             do: {:ok, %{spec | keys: {:regex, regex, match?}}, to}

      match? ->
        error("invalid WITH KEY clause, expected regular expression following =~", at)

      true ->
        {:error, "unsupported InfluxQL (WITH KEY !~ with no regular expression)"}
    end
  end

  defp key_name(ctx, after_op, op, spec) do
    case name_at(ctx, skip_ws(ctx, after_op)) do
      {:ok, name, to} ->
        {:ok, %{spec | keys: {op, name}}, to}

      {:error, _reason} = error ->
        error

      :none when op == :eq ->
        error("invalid WITH KEY clause, expected identifier following =", after_op)

      :none ->
        {:error, "unsupported InfluxQL (WITH KEY != with no name)"}
    end
  end

  defp key_list(ctx, after_in, spec) do
    open = skip_ws(ctx, after_in)

    cond do
      at_byte(ctx, open) != "(" ->
        error("invalid WITH KEY clause, expected identifier list following IN", after_in)

      ws?(ctx, open + 1) ->
        {:error, "unsupported InfluxQL (a blank after the parenthesis of WITH KEY IN)"}

      true ->
        key_names(ctx, open + 1, [], spec)
    end
  end

  defp key_names(ctx, at, acc, spec) do
    case name_at(ctx, at) do
      {:ok, name, to} -> key_names_more(ctx, to, [name | acc], spec)
      {:error, _reason} = error -> error
      :none -> error("invalid IN clause, expected identifier", at)
    end
  end

  # After a name: `,` and another, or `)`. A comma that no name follows is not
  # part of the list, the `)` is wanted at the end of the last name.
  defp key_names_more(ctx, to, acc, spec) do
    at = skip_ws(ctx, to)

    case at_byte(ctx, at) do
      ")" ->
        {:ok, %{spec | keys: {:in, Enum.reverse(acc)}}, at + 1}

      "," ->
        case name_at(ctx, skip_ws(ctx, at + 1)) do
          {:ok, name, after_name} -> key_names_more(ctx, after_name, [name | acc], spec)
          {:error, _reason} = error -> error
          :none -> error("invalid identifier list, expected ')'", to)
        end

      _other ->
        error("invalid identifier list, expected ')'", to)
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

  defp defer(spec, item), do: %{spec | deferred: [item | spec.deferred]}

  defp from_items(spec, items) do
    spec =
      Enum.reduce(items, spec, fn
        {:unavailable, message}, acc -> defer(acc, {:not_implemented, message})
        _source, acc -> acc
      end)

    %{
      spec
      | from: Enum.filter(items, &match?({kind, _name_or_regex} when kind in [:name, :regex], &1))
    }
  end

  # ---------------------------------------------------------------------------
  # Text helpers
  # ---------------------------------------------------------------------------

  @spec rest(ctx(), non_neg_integer()) :: binary()
  defp rest(ctx, at), do: binary_part(ctx.raw, at, ctx.size - at)

  @spec rest_starts?(ctx(), non_neg_integer(), binary()) :: boolean()
  defp rest_starts?(ctx, at, text) do
    size = byte_size(text)
    at + size <= ctx.size and binary_part(ctx.masked, at, size) == text
  end

  @spec at_byte(ctx(), non_neg_integer()) :: binary() | nil
  defp at_byte(ctx, at) when at < ctx.size, do: binary_part(ctx.masked, at, 1)
  defp at_byte(_ctx, _at), do: nil

  @spec ws?(ctx(), non_neg_integer()) :: boolean()
  defp ws?(ctx, at), do: at_byte(ctx, at) in [" ", "\t", "\n", "\r"]

  @spec skip_ws(ctx(), non_neg_integer()) :: non_neg_integer()
  defp skip_ws(ctx, at), do: if(ws?(ctx, at), do: skip_ws(ctx, at + 1), else: at)

  # The word at `at` (letters, digits, underscore) in lower case, and where it
  # ends.
  @spec word_at(ctx(), non_neg_integer()) :: {binary(), non_neg_integer()} | nil
  defp word_at(ctx, at) when at < ctx.size do
    case Regex.run(~r/^[A-Za-z_][A-Za-z0-9_]*/, binary_part(ctx.masked, at, ctx.size - at)) do
      [word] -> {String.downcase(word), at + byte_size(word)}
      nil -> nil
    end
  end

  defp word_at(_ctx, _at), do: nil

  @spec error(binary(), non_neg_integer()) :: {:error, {:engine, binary()}}
  defp error(message, at), do: {:error, {:engine, "#{@prefix}#{message} at pos #{at}"}}
end
