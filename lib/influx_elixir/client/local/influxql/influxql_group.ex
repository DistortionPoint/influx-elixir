defmodule InfluxElixir.Client.Local.InfluxQLGroup do
  @moduledoc false
  # The `GROUP BY` clause of an InfluxQL `SELECT`: tags, at most one
  # `time(every[, offset])` and a trailing `fill(...)` (verified):
  #
  #   * `every` is a positive duration (`1m`, `1h30m`), `offset` a duration with
  #     a sign, taken modulo `every`; both are whole microseconds, which is
  #     what the rows carry
  #   * `fill` is `null`, `none`, `previous`, `linear` (in any case) or a number
  #     (`1`, `-2`, `1.5`, `.5`); without `GROUP BY time` it changes nothing
  #   * what the double does not read is refused by name: a second `time()`,
  #     `time(0s)`, a call that is not durations, any other `fill` option

  alias InfluxElixir.Client.Local.{InfluxQLBuckets, InfluxQLText, InfluxQLTokens}

  @typedoc "A parsed `GROUP BY`; `fill` is `nil` when the clause has none."
  @type t :: %{
          tags: [binary()],
          time: nil | {pos_integer(), integer()},
          fill: InfluxQLBuckets.fill() | nil
        }

  @doc """
  Parses the text after `GROUP BY` (`\"\"` for none) and the option of the
  `fill()` after it (`nil` for none).
  """
  @spec parse(binary(), binary() | nil) :: {:ok, t()} | {:error, binary()}
  def parse(dimensions, fill_text) do
    with {:ok, fill} <- parse_fill(fill_text),
         {:ok, parts} <- parse_dimensions(dimensions) do
      times = for {:time, time} <- parts, do: time

      case times do
        [] -> {:ok, %{tags: for({:tag, tag} <- parts, do: tag), time: nil, fill: fill}}
        [time] -> {:ok, %{tags: for({:tag, tag} <- parts, do: tag), time: time, fill: fill}}
        _several -> {:error, "unsupported InfluxQL (GROUP BY with more than one time())"}
      end
    end
  end

  @spec parse_fill(binary() | nil) :: {:ok, InfluxQLBuckets.fill() | nil} | {:error, binary()}
  defp parse_fill(nil), do: {:ok, nil}

  defp parse_fill(option) do
    option = String.trim(option)

    cond do
      String.downcase(option) in ["null", "none", "previous", "linear"] ->
        {:ok, option |> String.downcase() |> String.to_atom()}

      Regex.match?(~r/^[+-]?(?:\d+(?:\.\d+)?|\.\d+)$/, option) ->
        {:ok, {:number, number(option)}}

      true ->
        {:error, "unsupported InfluxQL (fill(#{option}))"}
    end
  end

  @spec number(binary()) :: integer() | float()
  defp number(text) do
    if String.contains?(text, "."),
      do: text |> String.trim_leading("+") |> normalise() |> String.to_float(),
      else: text |> String.trim_leading("+") |> String.to_integer()
  end

  defp normalise("-." <> fraction), do: "-0." <> fraction
  defp normalise("." <> fraction), do: "0." <> fraction
  defp normalise(text), do: text

  @spec parse_dimensions(binary()) ::
          {:ok, [{:tag, binary()} | {:time, {pos_integer(), integer()}}]} | {:error, binary()}
  defp parse_dimensions(text) do
    text
    |> split_commas([], [], 0, nil)
    |> Enum.reduce_while({:ok, []}, fn piece, {:ok, acc} ->
      case dimension(String.trim(piece)) do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  # The pieces between the commas that are outside parentheses and quotes.
  @spec split_commas(binary(), [binary()], iodata(), non_neg_integer(), byte() | nil) ::
          [binary()]
  defp split_commas(<<>>, pieces, current, _depth, _quote),
    do: Enum.reverse([IO.iodata_to_binary(Enum.reverse(current)) | pieces])

  defp split_commas(<<q, rest::binary>>, pieces, current, depth, nil) when q in [?", ?'],
    do: split_commas(rest, pieces, [<<q>> | current], depth, q)

  defp split_commas(<<q, rest::binary>>, pieces, current, depth, q),
    do: split_commas(rest, pieces, [<<q>> | current], depth, nil)

  defp split_commas(<<?,, rest::binary>>, pieces, current, 0, nil),
    do: split_commas(rest, [IO.iodata_to_binary(Enum.reverse(current)) | pieces], [], 0, nil)

  defp split_commas(<<c, rest::binary>>, pieces, current, depth, nil) when c in [?(, ?)] do
    depth = if c == ?(, do: depth + 1, else: max(depth - 1, 0)
    split_commas(rest, pieces, [<<c>> | current], depth, nil)
  end

  defp split_commas(<<c, rest::binary>>, pieces, current, depth, quote),
    do: split_commas(rest, pieces, [<<c>> | current], depth, quote)

  @spec dimension(binary()) ::
          {:ok, {:tag, binary()} | {:time, {pos_integer(), integer()}}} | {:error, binary()}
  defp dimension(piece) do
    case Regex.run(~r/^time\s*\((.*)\)$/is, piece) do
      [_all, arguments] -> time_call(arguments)
      nil -> {:ok, {:tag, InfluxQLText.unquote_ident(piece)}}
    end
  end

  # `time(every)` and `time(every, offset)`.
  @spec time_call(binary()) :: {:ok, {:time, {pos_integer(), integer()}}} | {:error, binary()}
  defp time_call(arguments) do
    case InfluxQLTokens.tokenize(arguments, []) do
      {:ok, [{:duration, every, _text}]} -> time_dimension(every, 0)
      {:ok, [{:duration, every, _text}, {:raw, ","} | offset]} -> offset_call(every, offset)
      _other -> {:error, "unsupported InfluxQL (GROUP BY time(#{String.trim(arguments)}))"}
    end
  end

  defp offset_call(every, [{:duration, offset, _text}]), do: time_dimension(every, offset)

  defp offset_call(every, [{:raw, sign}, {:duration, offset, _text}]) when sign in ["+", "-"],
    do: time_dimension(every, if(sign == "-", do: -offset, else: offset))

  defp offset_call(_every, _other), do: {:error, "unsupported InfluxQL (GROUP BY time() offset)"}

  defp time_dimension(every, offset)
       when every > 0 and rem(every, 1000) == 0 and rem(offset, 1000) == 0,
       do: {:ok, {:time, {every, offset}}}

  defp time_dimension(_every, _offset),
    do: {:error, "unsupported InfluxQL (GROUP BY time() of zero or under a microsecond)"}
end
