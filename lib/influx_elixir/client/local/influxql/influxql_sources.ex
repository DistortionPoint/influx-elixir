defmodule InfluxElixir.Client.Local.InfluxQLSources do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
  # The list of sources after `FROM`, as the engine's parser reads it (verified): a source is a
  # name (bare, not a reserved word, or double-quoted) or a regular expression, and the list
  # is sources joined by commas. The list ends before the comma that no source follows (`FROM
  # m, LIMIT 1` and `FROM m,5` are left over from the comma). A bare name takes only letters,
  # digits and underscores: `m-1` is the source `m` and a leftover.
  #
  # A name followed by a `.` is a qualified name (`rp.m`, `db.rp.m`), which the double does not
  # read; a dot with no name after it (`m.`, `m.1`, `m.limit`) is no source, the engine's
  # "invalid FROM clause" where the source starts. Blanks may follow the dot, none may precede it.

  alias InfluxElixir.Client.Local.{InfluxQLLex, InfluxQLText}

  @typedoc "Where the sources end, or the source that does not read, or a qualified one."
  @type result ::
          {:ok, non_neg_integer()}
          | {:invalid, non_neg_integer(), non_neg_integer()}
          | {:qualified, non_neg_integer()}

  @doc """
  Reads the sources at the start of `tail` (the text after `FROM` and its blanks, literals
  masked): where the list ends, the offset of the source that does not read, or that of a
  qualified one.
  """
  @spec split(binary()) :: result()
  def split(tail) do
    case source(tail, 0) do
      {:ok, stop} -> more(tail, stop)
      other -> other
    end
  end

  # After a source: a comma and another source, else the list ends here.
  @spec more(binary(), non_neg_integer()) :: result()
  defp more(tail, stop) do
    at = skip(tail, stop)

    case tail do
      <<_before::binary-size(at), ?,, _rest::binary>> ->
        case source(tail, skip(tail, at + 1)) do
          {:ok, next_stop} -> more(tail, next_stop)
          {:none, _at} -> {:ok, stop}
          other -> other
        end

      _no_comma ->
        {:ok, stop}
    end
  end

  # A source at `at`: `{:ok, stop}`, `{:none, at}` where none starts, `{:invalid, at}` for a
  # name with a dot and no name after it, `{:qualified, at}` for one with a name after it.
  @spec source(binary(), non_neg_integer()) ::
          {:ok, non_neg_integer()}
          | {:none, non_neg_integer()}
          | {:invalid, non_neg_integer(), non_neg_integer()}
          | {:qualified, non_neg_integer()}
  defp source(tail, at) do
    rest = binary_part(tail, at, byte_size(tail) - at)

    cond do
      match = Regex.run(~q/\A\/(?:[^\/\\]|\\.)+\//, rest) ->
        {:ok, at + byte_size(hd(match))}

      match = Regex.run(~q/\A(?:"(?:[^"\\]|\\.)+"|[A-Za-z_]\w*)/, rest) ->
        name(tail, at, hd(match))

      true ->
        {:none, at}
    end
  end

  defp name(tail, at, word) do
    if InfluxQLText.reserved?(word),
      do: {:none, at},
      else: dotted(tail, at, at + byte_size(word))
  end

  defp dotted(tail, at, stop) do
    case tail do
      <<_before::binary-size(stop), ?., more::binary>> ->
        next = InfluxQLLex.trim_blanks(more)

        case Regex.run(~q/\A(?:"(?:[^"\\]|\\.)+"|[A-Za-z_]\w*)/, next) do
          [part] ->
            if InfluxQLText.reserved?(part),
              do: {:invalid, at, stop + 1 + byte_size(more) - byte_size(next)},
              else: {:qualified, at}

          nil ->
            empty_part(next, at, stop + 1 + byte_size(more) - byte_size(next))
        end

      _no_dot ->
        {:ok, stop}
    end
  end

  # `db..m`: a qualified name with an empty middle part.
  defp empty_part("." <> more, at, detect) do
    next = InfluxQLLex.trim_blanks(more)

    if Regex.match?(~q/\A(?:"(?:[^"\\]|\\.)+"|[A-Za-z_]\w*)/, next),
      do: {:qualified, at},
      else: {:invalid, at, detect}
  end

  defp empty_part(_next, at, detect), do: {:invalid, at, detect}

  defp skip(text, at) do
    rest = binary_part(text, at, byte_size(text) - at)
    at + byte_size(rest) - byte_size(InfluxQLLex.trim_blanks(rest))
  end
end
