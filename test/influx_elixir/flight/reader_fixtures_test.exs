defmodule InfluxElixir.Flight.ReaderFixturesTest do
  # Real Arrow Flight frames recorded from influxdb:3-core, each with the
  # rows the same query returned over HTTP. A row decoded from Flight must
  # be the map HTTP gives (after ResponseParser's coercion), whatever the
  # column types: structs from selector_*, lists from array_agg, durations,
  # Utf8View strings from string functions, dates, decimals, binary.
  # (docs/design/2026-09-26_flight-arrow-types.md)
  use ExUnit.Case, async: true

  alias InfluxElixir.Flight.Proto.FlightData
  alias InfluxElixir.Flight.Reader
  alias InfluxElixir.Query.ResponseParser

  @fixtures Path.expand("../../fixtures/flight", __DIR__)

  defp fixture(name) do
    %{frames: frames, http_rows: http_rows, sql: sql} =
      @fixtures |> Path.join(name <> ".etf") |> File.read!() |> :erlang.binary_to_term()

    {Enum.map(frames, &struct(FlightData, &1)),
     Enum.map(http_rows, &ResponseParser.coerce_types/1), sql}
  end

  @names ~w(mixed_flat struct_selectors struct_literal list_strings list_floats list_literal
            duration duration_forms utf8_view date decimal binary)

  # One byte changed, the frame cut short, a length made huge, or zeros put in: a corrupt
  # frame (a metadata length, a row count, a list offset) is an answer, never a raise, a
  # hang or a heap of gigabytes. The seed fixes the frames, so the test is deterministic.
  test "a corrupt frame of any fixture decodes to an answer within a bounded heap" do
    :rand.seed(:exsss, {7, 7, 7})

    for name <- @names, _round <- 1..30 do
      {frames, _http_rows, _sql} = fixture(name)
      index = :rand.uniform(length(frames)) - 1
      part = Enum.random([:data_header, :data_body])
      frames = List.update_at(frames, index, &Map.update!(&1, part, fn bin -> corrupt(bin) end))

      assert {:answered, answer} = decode_bounded(frames), "#{name}: #{inspect(part)}"
      assert match?({:ok, _rows}, answer) or match?({:error, _reason}, answer)
    end
  end

  defp corrupt(nil), do: corrupt(<<>>)
  defp corrupt(<<>>), do: <<:rand.uniform(256) - 1>>

  defp corrupt(bin) do
    at = :rand.uniform(byte_size(bin)) - 1
    <<before::binary-size(at), _byte, rest::binary>> = bin

    case :rand.uniform(4) do
      1 -> before <> <<:rand.uniform(256) - 1>> <> rest
      2 -> before
      3 -> before <> <<255, 255, 255, 127>> <> rest
      4 -> before <> <<0, 0, 0, 0>> <> rest
    end
  end

  # Decodes in a process whose heap is capped at about 40 MB; the cap kills it instead of
  # letting it take the machine's memory.
  defp decode_bounded(frames) do
    test = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: 5_000_000, kill: true, error_logger: false})
        send(test, {:decoded, self(), Reader.decode_flight_data(frames)})
      end)

    receive do
      {:decoded, ^pid, answer} -> {:answered, answer}
      {:DOWN, ^ref, :process, ^pid, reason} -> {:died, reason}
    end
  end

  for name <- @names do
    test "#{name}: Flight rows equal the HTTP rows" do
      {frames, http_rows, sql} = fixture(unquote(name))
      assert {:ok, ^http_rows} = Reader.decode_flight_data(frames), sql
    end
  end

  test "a selector struct keeps its time as a DateTime on both transports" do
    {frames, _http_rows, _sql} = fixture("struct_selectors")

    assert {:ok, [%{"sf" => %{"time" => %DateTime{}, "value" => 1.5}, "sm" => %{"value" => 7}}]} =
             Reader.decode_flight_data(frames)
  end

  test "an Interval column is refused by name rather than dropped" do
    {frames, _http_rows, _sql} = fixture("interval")

    assert {:error, {:unsupported_arrow_type, "Interval", "iv"}} =
             Reader.decode_flight_data(frames)
  end

  test "durations render as HTTP renders them" do
    for {ns, text} <- [
          {0, "P0D"},
          {60_000_000_000, "PT60S"},
          {500_000_000, "PT0.5S"},
          {-1, "-PT0.000000001S"},
          {7_199_750_000_000, "PT7199.75S"}
        ] do
      assert Reader.render_duration(ns) === text
    end
  end
end
