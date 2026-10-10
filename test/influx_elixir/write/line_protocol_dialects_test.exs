defmodule InfluxElixir.Write.LineProtocolDialectsTest do
  # InfluxDB 3 reads `\\` as one backslash; InfluxDB 2.7 never does in a name (verified on
  # 3.10.1 Core and 2.7.12), so the encoder writes a name for the server it is for
  # (docs/design/2026-10-10_review-of-71e2b8c.md). Every round trip below
  # was also run against a real 2.7 with the same strings and gave the same answers.
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.{HTTP, Local}
  alias InfluxElixir.{TestServer, TestSupport}
  alias InfluxElixir.Write.{BatchWriter, LineProtocol, Point}

  defp encode(point, opts \\ []), do: LineProtocol.encode(point, opts)

  describe "encode/2 — api_version" do
    test "v3 is the default and escapes a backslash everywhere" do
      point =
        Point.new("m\\x", %{"f\\k" => "s\\v"}, tags: %{"k\\k" => "a\\b"}, timestamp: 1)

      expected = ~S(m\\x,k\\k=a\\b f\\k="s\\v" 1)
      assert encode(point) === {:ok, expected}
      assert encode(point, api_version: :v3) === {:ok, expected}
    end

    test "v2 leaves a backslash in a name, and escapes it only in a string field value" do
      point =
        Point.new("m\\x", %{"f\\k" => "s\\v"}, tags: %{"k\\k" => "a\\b"}, timestamp: 1)

      assert encode(point, api_version: :v2) === {:ok, ~S(m\x,k\k=a\b f\k="s\\v" 1)}
    end

    test "v2 escapes the characters its parser undoes, per position" do
      point =
        Point.new("m a,b=c\"d", %{"f a,b=c\"d" => 1}, tags: %{"k a,b=c\"d" => "v a,b=c\"d"})

      assert encode(point, api_version: :v2) ===
               {:ok, ~S(m\ a\,b=c"d,k\ a\,b\=c"d=v\ a\,b\=c"d f\ a\,b\=c\"d=1i)}

      assert encode(point, api_version: :v3) ===
               {:ok, ~S(m\ a\,b=c"d,k\ a\,b\=c"d=v\ a\,b\=c"d f\ a\,b\=c"d=1i)}
    end

    test "v2 writes a backslash before an escaped character as the parser reads it" do
      # `\\,` is a backslash and an escaped comma on InfluxDB 2 (and a lone backslash then a
      # separator on 3): a tag value `a\,b` is written `a\\,b` for 2.
      point = Point.new("m", %{"f" => 1}, tags: %{"t" => ~S(a\,b)})
      assert encode(point, api_version: :v2) === {:ok, ~S(m,t=a\\,b f=1i)}
    end

    test "v2 refuses the names InfluxDB 2.7 cannot keep, which v3 writes escaped" do
      # `{name, the line v3 writes for it}`
      measurement = [
        {"a\\,b", ~S(a\\\,b f=1i)},
        {"a\\ b", ~S(a\\\ b f=1i)},
        {"a\\=b", ~S(a\\=b f=1i)},
        {~S(a\"b), ~S(a\\"b f=1i)},
        {"\\,", ~S(\\\, f=1i)}
      ]

      field_key = [
        {"a\\,b", ~S(m a\\\,b=1i)},
        {"a\\ b", ~S(m a\\\ b=1i)},
        {"a\\=b", ~S(m a\\\=b=1i)},
        {"\\,", ~S(m \\\,=1i)}
      ]

      for {name, v3_line} <- measurement do
        assert encode(Point.new(name, %{"f" => 1}), api_version: :v2) ===
                 {:error, {:invalid_measurement, name}}

        assert encode(Point.new(name, %{"f" => 1}), api_version: :v3) === {:ok, v3_line}
      end

      for {name, v3_line} <- field_key do
        assert encode(Point.new("m", %{name => 1}), api_version: :v2) ===
                 {:error, {:invalid_field_key, name}}

        assert encode(Point.new("m", %{name => 1}), api_version: :v3) === {:ok, v3_line}
      end

      # A backslash before a quote is fine in a field key (`f\\"` reads `f\"`) and in a tag.
      assert encode(Point.new("m", %{~S(a\"b) => 1}), api_version: :v2) ===
               {:ok, ~S(m a\\"b=1i)}

      assert encode(Point.new("m", %{"f" => 1}, tags: %{"a\\,b" => "c\\ d"}), api_version: :v2) ===
               {:ok, ~S(m,a\\,b=c\\ d f=1i)}
    end

    test "an api_version that is neither :v3 nor :v2 is an invalid option" do
      point = Point.new("m", %{"f" => 1})

      assert encode(point, api_version: :v4) === {:error, {:invalid_options, [api_version: :v4]}}

      assert encode(point, api_version: "v2") ===
               {:error, {:invalid_options, [api_version: "v2"]}}
    end
  end

  describe "encode/2 — never raises on what it is given" do
    test "a term that is not a point is an invalid point" do
      assert encode(:x) === {:error, {:invalid_point, :x}}
      assert encode(nil) === {:error, {:invalid_point, nil}}
      assert encode("cpu value=1") === {:error, {:invalid_point, "cpu value=1"}}
      assert encode([%{}]) === {:error, {:invalid_point, %{}}}
      assert encode([Point.new("m", %{"f" => 1}), :x]) === {:error, {:invalid_point, :x}}
    end

    test "a list that is not proper names its tail" do
      assert encode([Point.new("m", %{"f" => 1}) | :tail]) === {:error, {:invalid_point, :tail}}
    end

    test "options that are not a keyword list, or hold the wrong kind, are invalid options" do
      point = Point.new("m", %{"f" => 1})

      assert encode(point, :notkw) === {:error, {:invalid_options, :notkw}}
      assert encode(point, [:a, 1]) === {:error, {:invalid_options, [:a, 1]}}
      assert encode(point, nil) === {:error, {:invalid_options, nil}}
      assert encode(point, precision: {1}) === {:error, {:invalid_options, [precision: {1}]}}
      assert encode([], :notkw) === {:error, {:invalid_options, :notkw}}
    end

    test "fields and tags that are not maps make the point invalid" do
      list_fields = %Point{measurement: "m", fields: [f: 1], tags: %{}}
      list_tags = %Point{measurement: "m", fields: %{"f" => 1}, tags: [t: "a"]}

      assert encode(list_fields) === {:error, {:invalid_point, list_fields}}
      assert encode(list_tags) === {:error, {:invalid_point, list_tags}}
    end

    test "nil fields are none, and nil tags are none" do
      assert encode(%Point{measurement: "m", fields: nil}) === {:error, :empty_fields}
      assert encode(%Point{measurement: "m", fields: %{"f" => 1}, tags: nil}) === {:ok, "m f=1i"}
    end

    test "a point built from nil fields is refused by the encoder, not raised on" do
      assert encode(Point.new("m", nil)) === {:error, :empty_fields}
      assert encode(Point.new("m", nil, tags: nil)) === {:error, :empty_fields}
    end

    test "an empty list is an empty batch, and options are still read" do
      assert encode([]) === {:ok, ""}
      assert encode([], api_version: :v2) === {:ok, ""}
    end

    test "encode!/2 raises ArgumentError for every one of them" do
      assert_raise ArgumentError, "LineProtocol encode failed: {:invalid_point, :x}", fn ->
        LineProtocol.encode!(:x)
      end

      assert_raise ArgumentError, "LineProtocol encode failed: {:invalid_options, :x}", fn ->
        LineProtocol.encode!(Point.new("m", %{"f" => 1}), :x)
      end
    end
  end

  # What was stored is read back through Flux on the :v2 profile, whose name rules were
  # checked against InfluxDB 2.7.12 with these strings in these five positions.
  describe "v2 round trips on Client.Local (:v2 profile, as on InfluxDB 2.7)" do
    @strings [
      "a\\b",
      "a\\\\b",
      "a\\,b",
      "a\\ b",
      "a\\=b",
      "a,b",
      "a b",
      "a=b",
      "a\"b",
      "a\\\"b",
      "\\\\x",
      "a\\\\\\b",
      "x\\y\\z",
      "日本\\語",
      "\\n",
      "a\\\\,b",
      "a\\\\ b",
      "a\\\\=b",
      "a\\\\\"b",
      "\\,",
      "\\ ",
      "a\\\\\\,b",
      "a\\,\\,b",
      "\\=b",
      "a\\\\\\\\b"
    ]

    # The names InfluxDB 2.7 cannot keep (see "v2 refuses the names...").
    @unkeepable_measurements [
      "a\\,b",
      "a\\ b",
      "a\\=b",
      "a\\\"b",
      "a\\\\,b",
      "a\\\\ b",
      "a\\\\=b",
      "a\\\\\"b",
      "\\,",
      "\\ ",
      "a\\\\\\,b",
      "a\\,\\,b",
      "\\=b"
    ]
    @unkeepable_field_keys [
      "a\\,b",
      "a\\ b",
      "a\\=b",
      "a\\\\,b",
      "a\\\\ b",
      "a\\\\=b",
      "\\,",
      "\\ ",
      "a\\\\\\,b",
      "a\\,\\,b",
      "\\=b"
    ]

    setup do
      {:ok, conn} = Local.start(profile: :v2)
      :ok = Local.create_bucket(conn, "b", [])
      {:ok, conn: conn}
    end

    # Writes `point` at second `at` and returns the one row Flux reads back for that second.
    defp round_trip(conn, point, at) do
      {:ok, line} = encode(%{point | timestamp: at}, api_version: :v2)
      assert Local.write(conn, line, database: "b", precision: :second) === {:ok, :written}

      flux = ~s[from(bucket: "b") |> range(start: #{at}, stop: #{at + 1})]
      assert {:ok, [row]} = Local.query_flux(conn, flux, [])
      row
    end

    # The row Flux reads back for a point written at second `at`: the range is that second.
    defp flux_row(at, measurement, field, value, tags) do
      Map.merge(tags, %{
        "result" => "_result",
        "table" => 0,
        "_start" => DateTime.from_unix!(at * 1_000_000, :microsecond),
        "_stop" => DateTime.from_unix!((at + 1) * 1_000_000, :microsecond),
        "_time" => DateTime.from_unix!(at * 1_000_000, :microsecond),
        "_measurement" => measurement,
        "_field" => field,
        "_value" => value
      })
    end

    test "a measurement", %{conn: conn} do
      for {s, at} <- Enum.with_index(@strings, 1_000) do
        point = Point.new("m#{at}" <> s, %{"f" => 1}, tags: %{"t" => "v"})

        if s in @unkeepable_measurements do
          assert encode(point, api_version: :v2) ===
                   {:error, {:invalid_measurement, "m#{at}" <> s}}
        else
          assert round_trip(conn, point, at) ===
                   flux_row(at, "m#{at}" <> s, "f", 1, %{"t" => "v"}),
                 "measurement #{inspect(s)}"
        end
      end
    end

    test "a tag value", %{conn: conn} do
      for {s, at} <- Enum.with_index(@strings, 2_000) do
        tags = %{"t" => "v" <> s}
        point = Point.new("m#{at}", %{"f" => 1}, tags: tags)

        assert round_trip(conn, point, at) === flux_row(at, "m#{at}", "f", 1, tags),
               "tag value #{inspect(s)}"
      end
    end

    test "a tag key", %{conn: conn} do
      for {s, at} <- Enum.with_index(@strings, 3_000) do
        tags = %{("k" <> s) => "v"}
        point = Point.new("m#{at}", %{"f" => 1}, tags: tags)

        assert round_trip(conn, point, at) === flux_row(at, "m#{at}", "f", 1, tags),
               "tag key #{inspect(s)}"
      end
    end

    test "a field key", %{conn: conn} do
      for {s, at} <- Enum.with_index(@strings, 4_000) do
        point = Point.new("m#{at}", %{("f" <> s) => 1})

        if s in @unkeepable_field_keys do
          assert encode(point, api_version: :v2) === {:error, {:invalid_field_key, "f" <> s}}
        else
          assert round_trip(conn, point, at) === flux_row(at, "m#{at}", "f" <> s, 1, %{}),
                 "field key #{inspect(s)}"
        end
      end
    end

    test "a string field value", %{conn: conn} do
      for {s, at} <- Enum.with_index(@strings, 5_000) do
        point = Point.new("m#{at}", %{"f" => "x" <> s})

        assert round_trip(conn, point, at) === flux_row(at, "m#{at}", "f", "x" <> s, %{}),
               "string value #{inspect(s)}"
      end
    end

    test "a tag value of tens of thousands of backslashes before ordinary characters", %{
      conn: conn
    } do
      # The unescape of an unescaped backslash used to copy the rest of the text at each one:
      # 200,000 of them took seconds. The value is read back whole.
      value = String.duplicate("\\x", 50_000)
      point = Point.new("m", %{"f" => 1}, tags: %{"t" => value})
      assert round_trip(conn, point, 7_000) === flux_row(7_000, "m", "f", 1, %{"t" => value})
    end
  end

  describe "v3 round trips on Client.Local (:v3_core profile)" do
    setup do
      {:ok, conn} = Local.start(profile: :v3_core, databases: ["db"])
      {:ok, conn: conn}
    end

    test "a tag value and a string field keep their backslashes", %{conn: conn} do
      # `{value, how v3 writes it as a tag value, how it writes it inside a string field}`
      strings = [
        {~S(a\b), ~S(a\\b), ~S(a\\b)},
        {~S(a\\b), ~S(a\\\\b), ~S(a\\\\b)},
        {~S(a\,b), ~S(a\\\,b), ~S(a\\,b)},
        {~S(a\ b), ~S(a\\\ b), ~S(a\\ b)},
        {~S(a\=b), ~S(a\\\=b), ~S(a\\=b)},
        {~S(\\x), ~S(\\\\x), ~S(\\\\x)}
      ]

      for {{s, tag, string}, at} <- Enum.with_index(strings, 1) do
        point = Point.new("m#{at}", %{"f" => "x" <> s}, tags: %{"t" => "v" <> s}, timestamp: at)

        assert encode(point, api_version: :v3, precision: :second) ===
                 {:ok, ~s(m#{at},t=v#{tag} f="x#{string}" #{at})}

        line = ~s(m#{at},t=v#{tag} f="x#{string}" #{at})
        assert Local.write(conn, line, database: "db", precision: :second) === {:ok, :written}

        assert Local.query_sql(conn, "SELECT t, f FROM m#{at}", database: "db") ===
                 {:ok, [%{"t" => "v" <> s, "f" => "x" <> s}]}
      end
    end
  end

  describe "BatchWriter writes a Point for its connection's server" do
    setup do
      finch = :"fxi30_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch})
      test = self()

      # An owner of its own answers the request and passes the body on.
      owner =
        start_supervised!(
          {Task,
           fn ->
             receive do
               {:request, handler, body} ->
                 TestServer.respond(handler, 204)
                 send(test, {:body, body})
             end
           end}
        )

      {:ok, finch: finch, port: TestServer.controlled(owner: owner)}
    end

    for {version, expected} <- [{:v2, ~S(m,t=a\b a=1i 1)}, {:v3, ~S(m,t=a\\b a=1i 1)}] do
      test "an #{version} connection gets #{expected}", %{finch: finch, port: port} do
        connection = [
          host: "127.0.0.1",
          port: port,
          scheme: :http,
          token: "t",
          org: "o",
          database: "db",
          api_version: unquote(version),
          finch_name: finch
        ]

        writer =
          start_supervised!(
            {BatchWriter,
             connection: connection,
             client: HTTP,
             database: "db",
             batch_size: 1,
             flush_interval_ms: 600_000,
             jitter_ms: 0,
             max_retries: 0}
          )

        point = Point.new("m", %{"a" => 1}, tags: %{"t" => "a\\b"}, timestamp: 1)

        assert BatchWriter.write(writer, point) === :ok

        assert_receive {:body, body}, TestSupport.Await.bound()
        assert body === unquote(expected)
        :ok = BatchWriter.flush(writer)

        assert BatchWriter.stats(writer) ===
                 {:ok,
                  %{total_writes: 1, total_errors: 0, total_bytes: byte_size(unquote(expected))}}
      end
    end
  end
end
