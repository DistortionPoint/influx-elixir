defmodule InfluxElixir.Client.Local.InfluxQLSources do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
  # The list of sources after `FROM`, as the engine's parser reads it (verified): a source is a
  # name (bare, not a reserved word, or double-quoted) or a regular expression, and the list
  # is sources joined by commas. The list ends before the comma that no source follows (`FROM
  # m, LIMIT 1`, `FROM m,5` and `FROM m, m.` are left over from the comma). A bare name takes
  # only letters, digits and underscores: `m-1` is the source `m` and a leftover.
  #
  # A name may be qualified, up to three parts joined by dots, the last a name or a regular
  # expression: `rp.m`, `db.rp.m` and `db..m` (the retention policy empty). Blanks may follow a
  # dot, none may precede it, and the middle part of three may be empty only as `..`. A dot
  # with no name after it (`m.`, `m.1`, `m.limit`, `m.x.`, `m..limit`, `m. .x`) is no source,
  # the engine's "invalid FROM clause" where the source starts (for the first source of the list;
  # for a later one the list ends at its comma). A fourth part is left over from its dot.
  # What the qualifiers mean is in `InfluxQLParser`.

  alias InfluxElixir.Client.Local.{InfluxQLLex, InfluxQLText}

  @name ~S{"(?:[^"\\]|\\.)+"|[A-Za-z_]\w*}
  @regex ~S{/(?:[^/\\]|\\.)+/}
  @name_start ~q/\A(?:#{@name})/
  @regex_start ~q/\A#{@regex}/

  @typedoc """
  A source: its name or regular expression, and the parts written before it (`[]`, `[rp]`
  or `[database, rp]`, an empty retention policy `nil`).
  """
  @type source :: {{:name | :regex, binary()}, [binary() | nil]}

  @typedoc """
  The sources and where the list ends, the first source that does not read (`source_at`: where
  it starts, `wanted_at`: where the name that is missing should start), or none at all.
  """
  @type result ::
          {:ok, [source()], non_neg_integer()}
          | {:missing_name, %{source_at: non_neg_integer(), wanted_at: non_neg_integer()}}
          | :none

  @doc "The pattern of the start of one source, as a piece of a regular expression."
  @spec source_pattern() :: binary()
  def source_pattern, do: @regex <> "|" <> @name

  @doc """
  Reads the sources at the start of `masked`, the text after `FROM` and its blanks with its
  literals masked; `raw` is the same text as sent, which the names are read from.
  """
  @spec split(binary(), binary()) :: result()
  def split(masked, raw) do
    case source(masked, raw, 0) do
      {:ok, source, stop} -> more(masked, raw, [source], stop)
      other -> other
    end
  end

  # After a source: a comma and another source, else the list ends here. A comma with no source
  # after it (or one that does not read) is left over, with all that follows.
  @spec more(binary(), binary(), [source()], non_neg_integer()) :: result()
  defp more(masked, raw, sources, stop) do
    at = InfluxQLLex.skip_blanks(masked, stop)

    case masked do
      <<_before::binary-size(at), ?,, _rest::binary>> ->
        case source(masked, raw, InfluxQLLex.skip_blanks(masked, at + 1)) do
          {:ok, source, next_stop} -> more(masked, raw, [source | sources], next_stop)
          _none_or_missing -> {:ok, Enum.reverse(sources), stop}
        end

      _no_comma ->
        {:ok, Enum.reverse(sources), stop}
    end
  end

  @spec source(binary(), binary(), non_neg_integer()) ::
          {:ok, source(), non_neg_integer()} | {:missing_name, map()} | :none
  defp source(masked, raw, at) do
    case part(masked, at) do
      {:regex, size} -> {:ok, {value(:regex, raw, at, size), []}, at + size}
      {:name, size} -> qualified(masked, raw, at, [{:name, at, size}])
      _reserved_or_none -> :none
    end
  end

  # The parts after the first: each follows a dot (blanks may follow the dot), up to the third.
  @spec qualified(binary(), binary(), non_neg_integer(), [tuple()]) ::
          {:ok, source(), non_neg_integer()} | {:missing_name, map()}
  defp qualified(masked, raw, source_at, [{_kind, at, size} | _before] = parts) do
    stop = at + size

    case masked do
      <<_before::binary-size(stop), ?., ?., _rest::binary>> when length(parts) == 1 ->
        next(masked, raw, source_at, [nil | parts], stop + 2)

      <<_before::binary-size(stop), ?., _rest::binary>> when length(parts) < 3 ->
        next(masked, raw, source_at, parts, stop + 1)

      _no_more_parts ->
        {:ok, finished(raw, parts), stop}
    end
  end

  defp next(masked, raw, source_at, parts, after_dot) do
    wanted_at = InfluxQLLex.skip_blanks(masked, after_dot)

    case part(masked, wanted_at) do
      {:regex, size} ->
        {:ok, finished(raw, [{:regex, wanted_at, size} | parts]), wanted_at + size}

      {:name, size} ->
        qualified(masked, raw, source_at, [{:name, wanted_at, size} | parts])

      _reserved_or_none ->
        {:missing_name, %{source_at: source_at, wanted_at: wanted_at}}
    end
  end

  # The parts, last first (`nil` for the empty one), as the source they name.
  defp finished(raw, [{kind, at, size} | qualifiers]) do
    {value(kind, raw, at, size),
     qualifiers
     |> Enum.reverse()
     |> Enum.map(fn
       nil -> nil
       {_name, at, size} -> value(:name, raw, at, size) |> elem(1)
     end)}
  end

  defp value(:name, raw, at, size),
    do: {:name, raw |> binary_part(at, size) |> InfluxQLText.unquote_ident()}

  defp value(:regex, raw, at, size) do
    {:regex, raw |> binary_part(at + 1, size - 2) |> String.replace("\\/", "/")}
  end

  # A regular expression, or a name that is not a reserved word, at `at`.
  @spec part(binary(), non_neg_integer()) ::
          {:name | :regex, non_neg_integer()} | :reserved | :none
  defp part(masked, at) do
    rest = binary_part(masked, at, byte_size(masked) - at)

    cond do
      match = Regex.run(@regex_start, rest) ->
        {:regex, byte_size(hd(match))}

      match = Regex.run(@name_start, rest) ->
        word = hd(match)
        if InfluxQLText.reserved?(word), do: :reserved, else: {:name, byte_size(word)}

      true ->
        :none
    end
  end
end
