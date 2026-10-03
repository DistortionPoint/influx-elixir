defmodule InfluxElixir.Client.Local.InfluxQLFluxLPFidelityTest do
  @moduledoc """
  Unit tests for the line protocol grammar of both engines, the answers
  `Client.Local` gives where it refuses by name or models more than the
  shared contract reaches (InfluxQL and Flux through the client) and the
  store's atomicity. Every expectation was read from InfluxDB 3 Core or
  InfluxDB 2.7; the facts a real engine can be asked in the same words are
  in `InfluxElixir.Contract.InfluxQLFluxLP`.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Client.Local.{LineProtocolParser, Store}
  alias InfluxElixir.TestSupport.Await
  alias InfluxElixir.TestSupport.Tokens, as: TokenShape

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp parse_one(line, dialect) do
    assert {:ok, [result]} = LineProtocolParser.parse_lines(line, :nanosecond, dialect)
    result
  end

  defp v3_error(line) do
    assert {:error, %{error_message: message}} = parse_one(line, :v3)
    message
  end

  defp v2_error(line) do
    assert {:error, %{error_message: message, line: quoted}} = parse_one(line, :v2)
    {quoted, message}
  end

  defp v3_point(line) do
    assert {:ok, point, 1, _line} = parse_one(line, :v3)
    point
  end

  defp v2_point(line) do
    assert {:ok, point, 1, _line} = parse_one(line, :v2)
    point
  end

  defp point(measurement, tags, fields, timestamp \\ nil),
    do: %{measurement: measurement, tags: tags, fields: fields, timestamp: timestamp}

  defp parse_errors(text, dialect) do
    assert {:ok, results} = LineProtocolParser.parse_lines(text, :nanosecond, dialect)

    for {:error, %{line_number: n, error_message: message, original_line: shown}} <- results,
        do: {n, message, shown}
  end

  defp v2_errors(text) do
    assert {:ok, results} = LineProtocolParser.parse_lines(text, :nanosecond, :v2)
    for {:error, %{line: line, error_message: message}} <- results, do: {line, message}
  end

  # A connection's store dies with the test process, so nothing is stopped.
  defp v3_conn(databases \\ ["db"]) do
    {:ok, conn} = Local.start(databases: databases, profile: :v3_core)
    conn
  end

  defp v2_conn(buckets \\ ["b"]) do
    {:ok, conn} = Local.start(profile: :v2)
    Enum.each(buckets, &Local.create_bucket(conn, &1))
    conn
  end

  defp error_body(result) do
    assert {:error, %{body: body}} = result
    Jason.decode!(body)
  end

  # Returns once the clock reads later than it did, so that a second stamp
  # taken after this call cannot equal one taken before it. Fails the test,
  # rather than spinning on, if the clock never moves.
  defp let_the_clock_move do
    started = System.os_time(:nanosecond)
    Await.until(fn -> System.os_time(:nanosecond) > started end)
  end

  defp iql(conn, statement), do: Local.query_influxql(conn, statement, database: "db")

  defp flux_all(conn, tail),
    do: Local.query_flux(conn, ~s|from(bucket: "b") \|> range(start: 0) | <> tail)

  defp flux_range(conn, args),
    do: Local.query_flux(conn, ~s|from(bucket: "b") \|> range(#{args})|)

  defp wrap64(value) do
    wrapped = Bitwise.band(value, 0xFFFFFFFFFFFFFFFF)
    if wrapped >= 0x8000000000000000, do: wrapped - 0x10000000000000000, else: wrapped
  end

  @empty_range %{
    "code" => "invalid",
    "message" => "error in building plan while starting program: cannot query an empty range"
  }

  # Enough tasks at once that a race shows without a lucky schedule.
  @tasks 16

  # Runs `fun.(n)` for n in 1..count, each in a task of its own. The tasks
  # all wait for one message before they start, so they start together, and
  # the results come back in order of n.
  defp at_once(count, fun) do
    parent = self()

    tasks =
      for n <- 1..count do
        Task.async(fn ->
          send(parent, {:ready, n})

          receive do
            :go -> fun.(n)
          end
        end)
      end

    for n <- 1..count, do: assert_receive({:ready, ^n}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 30_000))
  end

  @minute_ns 60_000_000_000
  @hour_ns 3_600_000_000_000

  @drop_conflict "failure writing points to database: partial write: field type conflict: " <>
                   ~s|input field "v" on measurement "m" is type integer, | <>
                   "already exists as type float dropped="
  @drop_invalid "failure writing points to database: partial write: invalid field name: " <>
                  ~s|input field "time" on measurement "m" is invalid dropped=|

  defp drop_body(message), do: %{"code" => "unprocessable entity", "message" => message}

  defp stored(measurement, tags, v, timestamp),
    do: %{measurement: measurement, tags: tags, fields: %{"v" => v}, timestamp: timestamp}

  # The message with the clock's reading and the bucket's id masked, and the
  # bounds it printed.
  defp masked_retention(conn, bucket, body) do
    assert %{"code" => "unprocessable entity", "message" => message} = body
    assert {:ok, buckets} = Local.list_buckets(conn)
    assert %{"id" => id} = Enum.find(buckets, &(&1["name"] === bucket))

    bounds =
      ~r/Lower Bound at (\d{4}-[-\d:.TZ]+)/
      |> Regex.scan(message, capture: :all_but_first)
      |> List.flatten()

    masked =
      message
      |> String.replace(~r/Lower Bound at \d{4}-[-\d:.TZ]+/, "Lower Bound at BOUND")
      |> String.replace("database: #{id} ", "database: ID ")

    {masked, bounds}
  end

  @trailing "Could not parse entire line. Found trailing content: "
  @no_fields "No fields were provided"
  @need_space "Expected at least one space character, got end of input"

  # ---------------------------------------------------------------------------
  # Line protocol, InfluxDB 3
  # ---------------------------------------------------------------------------

  describe "InfluxDB 3 line protocol — the engine's errors" do
    test "most errors quote ten characters of what is left, and dots for the rest" do
      for {line, message} <- [
            {"zz v=1 abcdefghi", @trailing <> "` abcdefghi`"},
            {"zz v=1 abcdefghij", @trailing <> "` abcdefghi...`"},
            {"zz v=1 5 abcdefghijklmnop", @trailing <> "`abcdefghij...`"},
            {"zz v=1,w=abcdefghijklmnop", @trailing <> "`w=abcdefgh...`"},
            {"zz v=1,wwwwwwwwww", @trailing <> "`wwwwwwwwww`"},
            {"zz v=1,wwwwwwwwwwwwwww", @trailing <> "`wwwwwwwwww...`"},
            {"zz v=1 ééééééééééé", @trailing <> "` ééééééééé...`"},
            {"zz,t= abcdefghijklmnop v=1 5", "Expected tag value, got ` abcdefghi...`"},
            {"zz,=abcdefghijklmnop v=1 5", "Expected tag key, got `=abcdefghi...`"},
            {"zz,t=1,uuuuuuuuuuuuuuuuuuuuu v=1",
             "Tag set malformed: could not find equals sign in `t=1,uuuuuu...`"}
          ] do
        assert v3_error(line) === message, line
      end
    end

    test "\"Expected at least one space character\" quotes all of what is left" do
      assert v3_error("zz\tabcdefghijklmnop v=1") ===
               "Expected at least one space character, got `\tabcdefghijklmnop v=1`"
    end

    test "a number is the longest match; what follows is trailing content" do
      for {value, message} <- [
            {"5.", @trailing <> "`.`"},
            {"1e", @trailing <> "`e`"},
            {"0x10", @trailing <> "`x10`"},
            {"1_000", @trailing <> "`_000`"},
            {"1.5.5", @trailing <> "`.5`"},
            {"1i2", @trailing <> "`2`"},
            {"1ii", @trailing <> "`i`"},
            {"5.i", @trailing <> "`.i`"},
            {"1.0i", @trailing <> "`i`"},
            {"1e3i", @trailing <> "`i`"},
            {"1.e3", @trailing <> "`.e3`"},
            {"-5.", @trailing <> "`.`"},
            {"5.e1", @trailing <> "`.e1`"},
            {"-7u", @trailing <> "`u`"},
            {"5.u", @trailing <> "`.u`"},
            {"1.5u", @trailing <> "`u`"},
            {"1x", @trailing <> "`x`"}
          ] do
        assert v3_error("zz v=#{value}") === message, value
      end
    end

    test "what is not a value at all fails the field" do
      for value <-
            ~w(.5 -.5 +5 +1i .5i e1 NaN inf -inf Infinity --1 .e3 .5u x) ++ ["\"abc", "abc\""] do
        assert v3_error("zz v=#{value}") === @no_fields, value
      end
    end

    test "a boolean is the longest of true, True, TRUE, t, T and the false forms" do
      for {value, message} <- [
            {"true1", @trailing <> "`1`"},
            {"tRUE", @trailing <> "`RUE`"},
            {"TrUe", @trailing <> "`rUe`"},
            {"tru", @trailing <> "`ru`"}
          ] do
        assert v3_error("zz v=#{value}") === message, value
      end

      assert v3_point("zz a=T,b=f,c=True,d=FALSE") ===
               point("zz", %{}, %{"a" => true, "b" => false, "c" => true, "d" => false})
    end

    test "a string value ends at its closing quote" do
      assert v3_error(~s|zz v="a"b"|) === @trailing <> ~s|`b"`|
      assert v3_point(~S|zz v="a\"b"|) === point("zz", %{}, %{"v" => ~s|a"b|})
    end

    test "after the fields: whitespace and a timestamp, then nothing" do
      for {tail, message} <- [
            {" abc", @trailing <> "` abc`"},
            {" 1.5", @trailing <> "`.5`"},
            {" +5", @trailing <> "` +5`"},
            {" 1e3", @trailing <> "`e3`"},
            {" 0x1", @trailing <> "`x1`"},
            {"  ", @trailing <> "`  `"},
            {" 5 6 7", @trailing <> "`6 7`"},
            {" 5abc", @trailing <> "`abc`"},
            {" 5,6", @trailing <> "`,6`"},
            {" -", @trailing <> "` -`"},
            {" 99999999999999999999", "Unable to parse timestamp value `99999999999999999999`"}
          ] do
        assert v3_error("zz v=1#{tail}") === message, tail
      end

      for tail <- [" 5 ", " 5  ", "  5"] do
        assert v3_point("zz v=1#{tail}") === point("zz", %{}, %{"v" => 1.0}, 5)
      end

      assert v3_point("zz v=1 -5") === point("zz", %{}, %{"v" => 1.0}, -5)
    end

    test "the second field that fails leaves the line after its comma, later ones at it" do
      for {line, message} <- [
            {"zz v=1,w=", @trailing <> "`w=`"},
            {"zz v=1,w", @trailing <> "`w`"},
            {"zz v=1,=2", @trailing <> "`=2`"},
            {"zz v=1, w=2", @trailing <> "` w=2`"},
            {"zz v=1,w=2,x=", @trailing <> "`,x=`"},
            {"zz v=1,w=2,x", @trailing <> "`,x`"},
            {"zz v=1,w=2,", @trailing <> "`,`"},
            {"zz v=1,w=2,=3", @trailing <> "`,=3`"},
            {"zz v=1,w=2,x=3,y= 5", @trailing <> "`,y= 5`"},
            {"zz v=1,, ", @trailing <> "`, `"},
            {"zz v=1 ,w=2", @trailing <> "` ,w=2`"}
          ] do
        assert v3_error(line) === message, line
      end
    end

    test "a first field that fails is no fields at all" do
      for line <- ["zz =1", "zz v", "zz v= 1", "zz v =1", "zz ", "zz   ", "zz 5"] do
        assert v3_error(line) === @no_fields, line
      end

      assert v3_error("zz \"a b\"=1") === @no_fields
      assert v3_error(~s|zz a=1,"b c"=2|) === @trailing <> ~S|`"b c"=2`|
    end

    test "a tag set is read to its end, and quotes mean nothing in a name" do
      for {line, message} <- [
            {"zz,t v=1", "Tag set malformed: could not find equals sign in `t v=1`"},
            {"zz,t=1,u v=1", "Tag set malformed: could not find equals sign in `t=1,u v=1`"},
            {"zz,t", "Tag set malformed: could not find equals sign in `t`"},
            {"zz,t=1,u=2,w v=1",
             "Tag set malformed: could not find equals sign in `t=1,u=2,w ...`"},
            {"zz,t=1,u=2,, v=1",
             "Tag set malformed: could not find equals sign in `t=1,u=2,, ...`"},
            {"zz,,", "Tag set malformed: could not find equals sign in `,`"},
            {"zz,t= v=1", "Expected tag value, got ` v=1`"},
            {"zz,t=1,u= v=1", "Expected tag value, got ` v=1`"},
            {"zz,t=", "Expected tag value, got end of input"},
            {"zz,=1 v=1", "Expected tag key, got `=1 v=1`"},
            {"zz,t=1,=2 v=1", "Expected tag key, got `=2 v=1`"},
            {"zz, v=1", "Expected tag key, got ` v=1`"},
            {"zz,t=1,u=2, v=1", "Expected tag key, got ` v=1`"},
            {"zz,", "Expected tag key, got end of input"},
            {"zz,t=1,", "Expected tag key, got end of input"},
            {"zz,t=1", @need_space},
            {"zz,t=1,u=2", @need_space},
            {"justmeasurement", @need_space},
            {"zz,t=1 ", @no_fields},
            {",t=1 v=1", "Invalid measurement was provided"},
            {",", "Invalid measurement was provided"},
            {"m\"x y\" v=1", @no_fields},
            {~s|zz,t="a b" v=1|, @no_fields}
          ] do
        assert v3_error(line) === message, line
      end
    end

    test "a tag key may start with a comma or hold one; a tag value may hold an =" do
      for {line, tags} <- [
            {"zz,,t=1 v=1", %{",t" => "1"}},
            {"zz,t,u=1 v=1", %{"t,u" => "1"}},
            {"zz,t=1,,u=2 v=1", %{",u" => "2", "t" => "1"}},
            {"zz,t=a=b v=1", %{"t" => "a=b"}},
            {"zz,t==b v=1", %{"t" => "=b"}}
          ] do
        assert v3_point(line) === point("zz", tags, %{"v" => 1.0}), line
      end
    end

    test "a field key may hold commas and quotes; a trailing comma is accepted" do
      assert v3_point("zz a,b=1 5") === point("zz", %{}, %{"a,b" => 1.0}, 5)

      assert v3_point("zz v=1,w,x=2 5") ===
               point("zz", %{}, %{"w,x" => 2.0, "v" => 1.0}, 5)

      assert v3_point(~s|zz "k"=1 5|) === point("zz", %{}, %{~s|"k"| => 1.0}, 5)
      assert v3_point("zz v=1, 5") === point("zz", %{}, %{"v" => 1.0}, 5)
      assert v3_point("zz v=1,,w=2") === point("zz", %{}, %{"v" => 1.0, ",w" => 2.0})
      assert v3_point(~S|zz a\ b=1|) === point("zz", %{}, %{"a b" => 1.0})
    end

    test "numbers: the forms the engine reads and their types" do
      for {value, expected} <- [
            {"1.5e3", 1500.0},
            {"1E+3", 1000.0},
            {"1.5E-3", 0.0015},
            {"007", 7.0},
            {"9223372036854775807i", 9_223_372_036_854_775_807},
            {"1u", {:uint, 1}}
          ] do
        assert v3_point("zz v=#{value}") === point("zz", %{}, %{"v" => expected}), value
      end

      assert %{fields: %{"v" => zero}} = v3_point("zz v=-0")
      assert <<zero::float>> === <<-0.0::float>>
      assert v3_point("zz v=1 -5") === point("zz", %{}, %{"v" => 1.0}, -5)
    end

    test "a number outside what its type holds is its own error" do
      assert v3_error("zz v=9223372036854775808i") ===
               "Unable to parse integer value `9223372036854775808`"

      assert v3_error("zz v=18446744073709551616u") ===
               "Unable to parse unsigned integer value `18446744073709551616`"
    end

    test "a float too large for 64 bits is infinity on the engine, which the double refuses" do
      message =
        "Client.Local: the float 1e999 is infinity on InfluxDB 3 Core, " <>
          "which the double cannot hold"

      assert v3_error("zz v=1e999") === message
      assert v3_error("zz v=-2.5e999") === String.replace(message, "1e999", "-2.5e999")
    end

    test "a tag key given twice is accepted by the engine, which then fails every query" do
      assert v3_error("zz,t=1,t=1 v=1") ===
               "Client.Local: the tag key t is given twice; InfluxDB 3 Core stores such a " <>
                 "line and then answers every query of the table with a 500"

      assert v3_error(~S"zz,t\ x=1,t\ x=2 v=1") ===
               "Client.Local: the tag key t x is given twice; InfluxDB 3 Core stores such a " <>
                 "line and then answers every query of the table with a 500"
    end

    test "a field named twice, or also a tag: the first the line meets wins" do
      assert v3_error("zz,t=1 a=1,a=2,t=3") ===
               "invalid line protocol - multiple instances of 'a' field found"

      assert v3_error("zz,t=1 t=3,a=1,a=2") ===
               "invalid column type for column 't', expected iox::column_type::tag, " <>
                 "got iox::column_type::field::float"

      # A parse error comes before either.
      assert v3_error("zz v=1,v=2 abc") === @trailing <> "` abc`"
    end

    test "a tab ends a name as a space does, but a space alone separates the sections" do
      for {line, message} <- [
            {"zz\tv=1 5", "Expected at least one space character, got `\tv=1 5`"},
            {"zz,t=a\tb v=1", "Expected at least one space character, got `\tb v=1`"},
            {"zz,t\tx=1 v=1", "Tag set malformed: could not find equals sign in `t\tx=1 v=1`"},
            {"zz,\tt=1 v=1", "Expected tag key, got `\tt=1 v=1`"},
            {"zz,t=\t1 v=1", "Expected tag value, got `\t1 v=1`"},
            {"zz\tv=1", "Expected at least one space character, got `\tv=1`"},
            {"zz v\t=1", @no_fields},
            {"zz v=1,w\t=2", @trailing <> "`w\t=2`"},
            {"zz v=1\t5", @trailing <> "`\t5`"},
            {"zz v=1 5\t", @trailing <> "`\t`"},
            {"zz v=1,w=2,x\t=3", @trailing <> "`,x\t=3`"},
            {"zz v=2\",g=\t\"q \" 7", @trailing <> "`\",g=\t\"q \" ...`"}
          ] do
        assert v3_error(line) === message, line
      end

      # A tab inside a string, or escaped, is part of it.
      assert v3_point("zz v=\"a\tb\" 5") === point("zz", %{}, %{"v" => "a\tb"}, 5)
      assert v3_point("zz\\\tx v=1i 5") === point("zz\\\tx", %{}, %{"v" => 1}, 5)
    end

    test "a carriage return is a name's byte but ends a value or a timestamp" do
      assert v3_point("zz\rx,t=a\rb v=1i 5") ===
               point("zz\rx", %{"t" => "a\rb"}, %{"v" => 1}, 5)

      assert v3_error("zz v=1i\r") === @trailing <> "`\r`"
      assert v3_error("zz v=1i 5\r") === @trailing <> "`\r`"
    end

    test "blank lines and comments are skipped after leading blanks, and not counted" do
      assert {:ok, [{:ok, parsed, 1, "  m v=1"}]} =
               LineProtocolParser.parse_lines(
                 "\n  # a comment\n\t \n  m v=1\n",
                 :nanosecond,
                 :v3
               )

      assert parsed === point("m", %{}, %{"v" => 1.0})

      assert {:error, %{body: "incoming write was empty"}} =
               LineProtocolParser.parse_lines(" # only a comment", :nanosecond, :v3)
    end
  end

  describe "line splitting — what both engines do with a quote" do
    test "a quote opens a string only after an = that no comma has closed" do
      for dialect <- [:v3, :v2] do
        assert {:ok, [first, second]} =
                 LineProtocolParser.parse_lines(
                   ~s|m,t=a"b f=1i 1\nm f=2i 2|,
                   :nanosecond,
                   dialect
                 )

        assert first ===
                 {:ok, point("m", %{"t" => ~s|a"b|}, %{"f" => 1}, 1), 1, ~s|m,t=a"b f=1i 1|}

        assert second === {:ok, point("m", %{}, %{"f" => 2}, 2), 2, "m f=2i 2"}
      end
    end

    test "a quote in a measurement, a tag key or a field key means nothing" do
      for text <- [~s|m"a f=1i 1\nBAD|, ~s|m,k"x=1 f=1i 1\nBAD|, ~s|m f"x=1i 1\nBAD|] do
        assert [{2, @need_space, _echo}] = parse_errors(text, :v3), text
        assert [{"BAD", "missing fields"}] = v2_errors(text)
      end
    end

    test "InfluxDB 3: a quote after a field value opens a string that takes the next line" do
      assert parse_errors(~s|m f=1"i 1\nBAD|, :v3) ===
               [{1, @trailing <> ~s|`"i 1\nBAD`|, ~s|m f=1"i 1|}]
    end

    test "InfluxDB 3: a quote in the timestamp opens a string that takes the next line" do
      assert parse_errors(~s|m f=1i 1 "\nBAD|, :v3) ===
               [{1, @trailing <> ~s|`"\nBAD`|, ~s|m f=1i 1 "|}]
    end

    test "InfluxDB 2: a quote after a field value is part of the number's line" do
      assert v2_errors(~s|m f=1"i 1\nBAD|) === [{~s|m f=1"i 1\nBAD|, "invalid number"}]
    end

    test "a quote after a comma that closes the = opens nothing" do
      for text <- [~s|m f=1i,"\nBAD|, ~s|m f=1i, "g\nBAD|, ~s|m f="a,b",g,"\nBAD|] do
        assert [{1, _first, _echoed}, {2, @need_space, _echo}] = parse_errors(text, :v3), text
      end
    end

    test "a backslash takes the next byte with it, a newline too" do
      assert [{1, @need_space, "BAD1\\"}, {2, @need_space, "BAD2"}] =
               parse_errors("BAD1\\\nBAD2\nBAD3", :v3)

      assert v2_errors("BAD1\\\nBAD2\nBAD3") ===
               [{"BAD1\\\nBAD2", "missing fields"}, {"BAD3", "missing fields"}]
    end

    test "a newline inside a string value is part of the value" do
      assert {:ok, [{:ok, parsed, 1, _line}, {:ok, _second, 2, _text}]} =
               LineProtocolParser.parse_lines(
                 ~s|m f="a\nb" 1\nm f=2i 2|,
                 :nanosecond,
                 :v3
               )

      assert parsed === point("m", %{}, %{"f" => "a\nb"}, 1)
    end

    test "InfluxDB 3 skips a comment through its physical line" do
      assert [{1, @need_space, ~s|# a=1 "x|}] = parse_errors(~s|# a=1 "x\nBAD|, :v3)
    end

    test "InfluxDB 2 skips a comment through the whole line a quote leaves open" do
      assert {:error, %{body: "incoming write was empty"}} =
               LineProtocolParser.parse_lines(~s|# a=1 "x\nBAD|, :nanosecond, :v2)
    end

    test "InfluxDB 2 does not count a final newline in a line a quote left open" do
      assert v2_errors(~s|m f="a\nBAD\n|) === [{~s|m f="a\nBAD|, "unbalanced quotes"}]
    end
  end

  # A payload is parsed in chunks of 10,000 lines, so a payload has to exceed
  # 10,000 lines for a chunk boundary to be crossed. These write just enough
  # lines for bad ones to fall on either side of the first boundary (and, in
  # the one test that numbers errors, the second) and read the numbers the
  # error body gives.
  describe "write/3 — a payload of many lines" do
    @one_boundary 10_001
    @two_boundaries 20_001
    @first_boundary [9_999, 10_000, 10_001]
    @both_boundaries [9_999, 10_000, 10_001, 19_999, 20_000, 20_001]

    defp many_lines(count, bad) do
      Enum.map_join(1..count, "\n", fn i ->
        if i in bad, do: "BAD#{i}", else: "m v=#{i}i #{i}"
      end)
    end

    test "every point of a payload is stored, whichever chunk it is in" do
      conn = v3_conn()
      assert {:ok, :written} = Local.write(conn, many_lines(@one_boundary, []), database: "db")

      assert {:ok, rows} = iql(conn, "SELECT v FROM m")
      assert Enum.map(rows, & &1["v"]) === Enum.to_list(1..@one_boundary)
    end

    test "InfluxDB 3 numbers and echoes an error in any chunk, and writes the other lines" do
      conn = v3_conn()

      assert {:error, %{status: 400, body: body}} =
               Local.write(conn, many_lines(@two_boundaries, @both_boundaries), database: "db")

      assert %{"data" => data} = Jason.decode!(body)

      assert for(%{"line_number" => n, "original_line" => shown} <- data, do: {n, shown}) ===
               for(i <- @both_boundaries, do: {i, "BAD#{i}"})

      assert iql(conn, "SELECT count(v) FROM m") ===
               {:ok,
                [
                  %{
                    "iox::measurement" => "m",
                    "time" => ~U[1970-01-01 00:00:00.000000Z],
                    "count" => @two_boundaries - length(@both_boundaries)
                  }
                ]}
    end

    test "InfluxDB 2 quotes the line of an error in any chunk, in order" do
      conn = v2_conn()

      assert {:error, %{status: 400, body: body}} =
               Local.write(conn, many_lines(@one_boundary, @first_boundary), database: "b")

      assert Jason.decode!(body)["message"] ===
               Enum.map_join(
                 @first_boundary,
                 "\n",
                 &"unable to parse 'BAD#{&1}': missing fields"
               )
    end

    test "comments and blank lines are not numbered, wherever the chunks fall" do
      conn = v3_conn()

      # Every third line is a comment, so physical line i is line i - div(i, 3).
      bad = [14_999, 15_001]

      payload =
        Enum.map_join(1..15_002, "\n", fn i ->
          cond do
            rem(i, 3) == 0 -> "# c#{i}"
            i in bad -> "BAD#{i}"
            true -> "m v=1i #{i}"
          end
        end)

      assert {:error, %{status: 400, body: body}} = Local.write(conn, payload, database: "db")
      assert %{"data" => data} = Jason.decode!(body)

      # The engine echoes the physical line that has the error's number.
      assert for(%{"line_number" => n, "original_line" => shown} <- data, do: {n, shown}) ===
               [{10_000, "m v=1i 10000"}, {10_001, "m v=1i 10001"}]
    end

    test "a payload of only comments is empty" do
      conn = v3_conn()
      text = Enum.map_join(1..@one_boundary, "\n", &"# c#{&1}")

      assert {:error, %{status: 400, body: "incoming write was empty"}} =
               Local.write(conn, text, database: "db")
    end
  end

  describe "line numbers — the engine counts the lines that are not blank or comments" do
    test "an error is numbered among them and echoes the physical line with that number" do
      assert parse_errors("#c\nBAD1\nBAD2\nBAD3", :v3) ===
               [{1, @need_space, "#c"}, {2, @need_space, "BAD1"}, {3, @need_space, "BAD2"}]

      assert parse_errors("\nBAD", :v3) === [{1, @need_space, ""}]

      assert parse_errors("BAD1\n#c\n\nBAD2\nBAD3", :v3) ===
               [{1, @need_space, "BAD1"}, {2, @need_space, "#c"}, {3, @need_space, ""}]
    end

    test "a point's number is its place among them" do
      assert {:ok, [{:ok, _a, 1, "m v=1"}, {:ok, _b, 2, "m v=2"}]} =
               LineProtocolParser.parse_lines("#c\nm v=1\n\nm v=2\n#d", :nanosecond, :v3)
    end

    test "the echo is cut to 20 characters and loses a carriage return" do
      assert [{1, @trailing <> "`\r`", "zz v=1i"}, {2, @need_space, "BAD"}] =
               parse_errors("zz v=1i\r\nBAD", :v3)

      # The last line has no newline to take a carriage return with it.
      assert [{1, @trailing <> "`\r`", "zz v=1i\r"}] = parse_errors("zz v=1i\r", :v3)

      assert [{1, @need_space, "abcdefghijklmnopqrst"}] =
               parse_errors("abcdefghijklmnopqrstuvwxyz", :v3)
    end
  end

  describe "line protocol — quotes and escapes in names" do
    test "a measurement in quotes keeps its quotes on both engines" do
      for dialect <- [:v3, :v2] do
        assert dialect |> then(&parse_one(~s|"m" f=1i 1|, &1)) ===
                 {:ok, point(~s|"m"|, %{}, %{"f" => 1}, 1), 1, ~s|"m" f=1i 1|}
      end
    end

    test "a quote is an ordinary byte in a tag key, a tag value and a field key" do
      for dialect <- [:v3, :v2] do
        assert {:ok, parsed, 1, _line} = parse_one(~s|m,"k"="v" "f"=1i 1|, dialect)
        assert parsed === point("m", %{~s|"k"| => ~s|"v"|}, %{~s|"f"| => 1}, 1)
      end
    end

    test "InfluxDB 3 undoes \\\\, \\, and \\<space> everywhere, \\= outside a measurement" do
      for {suffix, tag_value, measurement} <- [
            {~S|\,x|, "a,x", ",x"},
            {~S|\ x|, "a x", " x"},
            {~S|\=x|, "a=x", ~S|\=x|},
            {~S|\"x|, ~S|a\"x|, ~S|\"x|},
            {~S|\\x|, ~S|a\x|, ~S|\x|},
            {~S|\\=x|, ~S|a\=x|, ~S|\=x|},
            {~S|\\\,x|, ~S|a\,x|, ~S|\,x|},
            {~S|\\\\x|, ~S|a\\x|, ~S|\\x|},
            {~S|\x|, ~S|a\x|, ~S|\x|}
          ] do
        assert v3_point("m,k=a#{suffix} v=1i 1") ===
                 point("m", %{"k" => tag_value}, %{"v" => 1}, 1)

        assert v3_point("m#{suffix} v=1i 1") === point("m" <> measurement, %{}, %{"v" => 1}, 1)
      end
    end

    test "InfluxDB 2 undoes only an escape of its set and keeps every other backslash" do
      for {suffix, tag_value} <- [
            {~S|\,x|, "a,x"},
            {~S|\ x|, "a x"},
            {~S|\=x|, "a=x"},
            {~S|\"x|, ~S|a\"x|},
            {~S|\\x|, ~S|a\\x|},
            {~S|\\,x|, ~S|a\,x|},
            {~S|\\ x|, ~S|a\ x|},
            {~S|\\=x|, ~S|a\=x|},
            {~S|\\\,x|, ~S|a\\,x|},
            {~S|\\\\x|, ~S|a\\\\x|},
            {~S|\x|, ~S|a\x|}
          ] do
        assert v2_point("m,k=a#{suffix} v=1i 1") ===
                 point("m", %{"k" => tag_value}, %{"v" => 1}, 1)
      end

      # A field key and a measurement also undo \".
      assert v2_point(~S|m v\"x=1i 1|) === point("m", %{}, %{~S|v"x| => 1}, 1)

      assert v2_point(~S|m\"x v=1i 1|) ===
               Map.put(point(~S|m"x|, %{}, %{"v" => 1}, 1), :unreadable, true)
    end

    test "InfluxDB 2 accepts a measurement it never returns: the point is marked unreadable" do
      for suffix <- [~S|\=x|, ~S|\"x|, ~S|\\,x|, ~S|\\ x|, ~S|\\=x|, ~S|\\"x|, ~S|\\\,x|] do
        assert %{unreadable: true} = v2_point("m#{suffix} v=1i 1"), suffix
      end

      for suffix <- [~S|\,x|, ~S|\ x|, ~S|\\x|, ~S|\\\\x|, ~S|\x|, ~S|"x|, ~S|x"|] do
        refute Map.has_key?(v2_point("m#{suffix} v=1i 1"), :unreadable), suffix
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Line protocol, InfluxDB 2
  # ---------------------------------------------------------------------------

  describe "InfluxDB 2 line protocol — the Go parser's errors" do
    test "the key block" do
      for {line, reason} <- [
            {"zz", "missing fields"},
            {"zz,t=1", "missing fields"},
            {"zz,t=a\\", "missing fields"},
            {",t=1 v=1", "missing measurement"},
            {",", "missing measurement"},
            {"zz,t v=1", "missing tag value"},
            {"zz,t=1,u v=1", "missing tag value"},
            {"zz,t= v=1", "missing tag value"},
            {"zz,t", "missing tag value"},
            {"zz,t=", "missing tag value"},
            {"zz,=1 v=1", "missing tag key"},
            {"zz, v=1", "missing tag key"},
            {"zz,,t=1 v=1", "missing tag key"},
            {"zz,", "missing tag key"},
            {"zz,t=a=b v=1", "invalid tag format"},
            {"zz,t=1,t=2 v=1", "duplicate tags"},
            {"zz,t=1,t=2 v=", "duplicate tags"},
            {"zz,t=a\\,b,t=a\\,b v=1", "duplicate tags"}
          ] do
        assert v2_error(line) === {line, reason}, line
      end
    end

    test "an escape is judged by the byte before it" do
      # `\\,` is not a separator: the measurement keeps the backslash and
      # loses the escape of the comma, and its point is never returned.
      assert v2_point(~S"bs\\,t=a v=1i 1") ===
               Map.put(point(~S"bs\,t=a", %{}, %{"v" => 1}, 1), :unreadable, true)

      assert v2_point(~S"bs\,t=a v=1i 1") === point("bs,t=a", %{}, %{"v" => 1}, 1)
      assert v2_error(~S"zq\\ v=1i 5") === {~S"zq\\ v=1i 5", "invalid field format"}
      assert v2_error(~S"zq,t=a\\ v=1i 5") === {~S"zq,t=a\\ v=1i 5", "invalid tag format"}
      assert v2_error(~S"zq,t\\ v=1i 5") === {~S"zq,t\\ v=1i 5", "invalid field format"}
      assert v2_error(~S"zq,t\\=1 v=1i") === {~S"zq,t\\=1 v=1i", "missing tag value"}
      assert v2_error(~S"zq,t=\\ v=1i") === {~S"zq,t=\\ v=1i", "invalid tag format"}
      assert v2_error(~S"zq,t\\") === {~S"zq,t\\", "missing tag value"}
      assert v2_error(~S"zq\\") === {~S"zq\\", "missing fields"}
    end

    test "the fields block" do
      for {line, reason} <- [
            {"zz =1", "missing field key"},
            {"zz v=1,=2", "missing field key"},
            {"zz v=", "missing field value"},
            {"zz v=,w=1", "missing field value"},
            {"zz v=1,w=", "missing field value"},
            {"zz v", "invalid field format"},
            {"zz 5", "invalid field format"},
            {"zz ", "invalid field format"},
            {"zz v=1,w", "invalid field format"},
            {"zz v=1,,w=2", "invalid field format"},
            {"zz v=1,", "invalid field format"},
            {~S"zz a\=1", "invalid field format"},
            {~S"zz v\\ =1i 5", "invalid field format"},
            {~S|zz "a b"=1|, "invalid field format"},
            {~S|zz v="abc|, "unbalanced quotes"},
            {~S|zz v="a"b"|, "unbalanced quotes"},
            {"zz v=1_000", "invalid number"},
            {"zz v=1.5.5", "invalid number"},
            {"zz v=1ii", "invalid number"},
            {"zz v=1i2", "invalid number"},
            {"zz v=-", "invalid number"},
            {"zz v=-i", "invalid number"},
            {"zz v=NaN", "invalid number"},
            {"zz v=nan", "invalid number"},
            {"zz v=-inf", "invalid number"},
            {"zz v=-7u", "invalid number"},
            {"zz v=1e3i", "invalid number"},
            {"zz v=1=2", "invalid number"},
            {"zz v=..", "invalid number"},
            {"zz v=-.", "invalid number"},
            {"zz v=1e", "invalid float"},
            {"zz v=.e3", "invalid float"},
            {"zz v=1e5e5", "invalid float"},
            {"zz v=1e+", "invalid float"},
            {"zz v=1e999", "invalid float"},
            {"zz v=+5", "invalid boolean"},
            {"zz v=e1", "invalid boolean"},
            {"zz v=inf", "invalid boolean"},
            {"zz v=tRUE", "invalid boolean"},
            {"zz v=true1", "invalid boolean"},
            {"zz v=tr", "invalid boolean"},
            {"zz v==1", "invalid boolean"},
            {"zz v=x", "invalid boolean"}
          ] do
        assert v2_error(line) === {line, reason}, line
      end
    end

    test "the time block, and what may follow it" do
      for {line, reason} <- [
            {"zz v=1 abc", "bad timestamp"},
            {"zz v=1 1.5", "bad timestamp"},
            {"zz v=1 +5", "bad timestamp"},
            {"zz v=1 1e3", "bad timestamp"},
            {"zz v=1 5\t", "bad timestamp"},
            {"zz v=1 5\r", "bad timestamp"},
            {"zz v=1 -", ~S|strconv.ParseInt: parsing "-": invalid syntax|},
            {"zz v=1 99999999999999999999",
             ~S|strconv.ParseInt: parsing "99999999999999999999": value out of range|},
            {"zz v=1 9223372036854775807",
             "time outside range -9223372036854775806 - 9223372036854775806"},
            {"zz v=1 5 6", "point is invalid"},
            {"zz v=1 5 #x", "point is invalid"},
            {"zz v=1 100 200", "point is invalid"}
          ] do
        assert v2_error(line) === {line, reason}, line
      end

      for {tail, timestamp} <- [
            {"", nil},
            {" 5", 5},
            {"  5", 5},
            {" 5 ", 5},
            {" 5   ", 5},
            {" -5", -5}
          ] do
        assert v2_point("zz v=1" <> tail) === point("zz", %{}, %{"v" => 1.0}, timestamp), tail
      end
    end

    test "numbers outside what their type holds" do
      assert v2_error("zz v=9223372036854775808i") ===
               {"zz v=9223372036854775808i",
                "unable to parse integer 9223372036854775808: " <>
                  ~S|strconv.ParseInt: parsing "9223372036854775808": value out of range|}

      assert v2_error("zz v=-9223372036854775809i") ===
               {"zz v=-9223372036854775809i",
                "unable to parse integer -9223372036854775809: " <>
                  ~S|strconv.ParseInt: parsing "-9223372036854775809": value out of range|}

      assert v2_error("zz v=18446744073709551616u") ===
               {"zz v=18446744073709551616u",
                "unable to parse unsigned 18446744073709551616: " <>
                  ~S|strconv.ParseUint: parsing "18446744073709551616": value out of range|}
    end

    test "a field key that ends in a backslash is refused after the line scans" do
      assert v2_error(~S"zz v\\=1i 5") ===
               {~S"zz v\\=1i 5", ~S"invalid value: field-key=v\\=1i"}

      assert v2_error(~S"zz v=1i,w\\=1i") ===
               {~S"zz v=1i,w\\=1i", ~S"invalid value: field-key=w\\=1i"}
    end

    test "floats like 5. and .5 are floats; a string takes its last byte off" do
      for {value, expected} <- [
            {"5.", 5.0},
            {".5", 0.5},
            {"-.5", -0.5},
            {"1.e1", 10.0},
            {"5.e1", 50.0},
            {~S|"x"|, "x"},
            # InfluxDB 2 drops the last byte of the value, whatever it is.
            {"\"x\"\r", ~S|x"|},
            {~S|"a\"b"|, ~S|a"b|}
          ] do
        assert v2_point("zz v=#{value}") === point("zz", %{}, %{"v" => expected}), value
      end

      assert v2_point(~S|zz a\ b=1|) === point("zz", %{}, %{"a b" => 1.0})
      assert v2_point(~s|zz "k"=1|) === point("zz", %{}, %{~s|"k"| => 1.0})
      assert v2_point("zz v=T,w=false") === point("zz", %{}, %{"v" => true, "w" => false})
    end

    test "time as a field is dropped, as a tag refused" do
      assert v2_point("zz time=1,v=2") === point("zz", %{}, %{"v" => 2.0})
      assert v2_point("zz time=1") === point("zz", %{}, %{})

      assert v2_error("zz,time=x v=1") ===
               {"zz,time=x v=1", ~s|cannot use reserved tag key "time"|}
    end

    test "the line is quoted without its leading whitespace" do
      assert v2_error(" \t zz v=") === {"zz v=", "missing field value"}
      assert v2_point("\t zz v=1") === point("zz", %{}, %{"v" => 1.0})

      assert {:error, %{body: "incoming write was empty"}} =
               LineProtocolParser.parse_lines("\0 \t\n  # c", :nanosecond, :v2)
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxQL through the double
  # ---------------------------------------------------------------------------

  describe "query_influxql/3 — what the double refuses by name" do
    setup do
      conn = v3_conn()
      {:ok, :written} = Local.write(conn, "o,k=a v=1,w=10 1000", database: "db")
      {:ok, conn: conn}
    end

    test "a WHERE it does not model", %{conn: conn} do
      for {where, message} <- [
            {"time > 0.5", "Client.Local: unsupported InfluxQL (non-integer time 0.5)"},
            {"time >= 2 OR k = 'a'",
             "Client.Local: unsupported InfluxQL (a time comparison inside OR)"},
            {"k = 'a' OR (k = 'b' AND time >= 2)",
             "Client.Local: unsupported InfluxQL (a time comparison inside OR)"},
            {"time > 1 * 2",
             "Client.Local: unsupported InfluxQL (a time compared with an expression)"}
          ] do
        assert iql(conn, "SELECT v FROM o WHERE #{where}") ===
                 {:error, %{status: 400, body: message}},
               where
      end
    end

    test "a clause it does not model, outside a literal", %{conn: conn} do
      for {statement, name} <- [
            {"SELECT v INTO x FROM o", "INTO"},
            {"SELECT v FROM o SLIMIT 1", "SLIMIT/SOFFSET"},
            {"SELECT v FROM (SELECT v FROM o)", "subqueries"},
            {"SELECT mean(v) FROM o GROUP BY time(1)", "GROUP BY time(1)"},
            {"SELECT mean(v) FROM o GROUP BY time(0s)",
             "GROUP BY time() of zero or under a microsecond"},
            {"SELECT mean(v) FROM o GROUP BY time(1m), time(2m)",
             "GROUP BY with more than one time()"},
            {"SELECT mean(v) FROM o GROUP BY time(1m) fill( linear2 )", "fill(linear2)"},
            {"SELECT v FROM o GROUP BY *", "GROUP BY *"},
            {"SELECT v FROM o WHERE k = 'a' tz('UTC')", "tz()"}
          ] do
        assert iql(conn, statement) ===
                 {:error,
                  %{
                    status: 400,
                    body: "Client.Local: unsupported InfluxQL (#{name}): #{statement}"
                  }},
               statement
      end
    end

    test "a keyword inside a literal is no keyword, however long the literal", %{conn: conn} do
      long = String.duplicate("x", 5_000)

      for literal <- [
            "into",
            "fill(",
            "group by time(1m)",
            "slimit 1",
            "tz(x)",
            "it\\'s into",
            long
          ] do
        assert {:ok, []} = iql(conn, "SELECT v FROM o WHERE k = '#{literal}'"), literal
      end

      assert {:ok, []} = iql(conn, "SELECT v FROM o WHERE k =~ /fill\\(/")

      assert iql(conn, "SELECT v FROM o WHERE k = 'a' LIMIT 5") ===
               {:ok,
                [
                  %{
                    "iox::measurement" => "o",
                    "time" => ~U[1970-01-01 00:00:00.000001Z],
                    "v" => 1.0
                  }
                ]}
    end
  end

  describe "query_influxql/3 — answers the contract does not reach" do
    setup do
      conn = v3_conn()

      lp = """
      o,k=a v=1,w=10 1000
      o,k=b v=2,w=20 2000
      o,k=a v=3,w=30 3000
      o,k=into v=4,w=40 4000
      o,k=c x=7i 5000
      """

      {:ok, :written} = Local.write(conn, String.trim(lp), database: "db")
      {:ok, conn: conn}
    end

    test "a bound taken from now() is stamped on the aggregate", %{conn: conn} do
      assert {:ok, []} = iql(conn, "SELECT mean(v) FROM o WHERE time > now() - 1h")

      assert {:ok, :written} =
               Local.write(conn, "fresh v=1 #{System.os_time(:nanosecond)}", database: "db")

      # `time > x` starts one nanosecond after x, and the row carries whole
      # microseconds: the stamp lies between the bounds of a bracket of the
      # call, whatever the clock reads in it.
      first = Store.now_ns()
      answer = iql(conn, "SELECT mean(v) FROM fresh WHERE time > now() - 1h")
      last = Store.now_ns()

      assert {:ok, [%{"time" => time} = row]} = answer
      assert Map.delete(row, "time") === %{"iox::measurement" => "fresh", "mean" => 1.0}
      stamp = DateTime.to_unix(time, :microsecond)
      assert stamp >= Integer.floor_div(first - @hour_ns + 1, 1_000)
      assert stamp <= Integer.floor_div(last - @hour_ns + 1, 1_000)
    end

    test "a tag equal to '' finds the points that lack the tag", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "o v=9,w=90 6000", database: "db")

      assert {:ok, rows} = iql(conn, "SELECT v FROM o WHERE k = ''")
      assert Enum.map(rows, & &1["v"]) === [9.0]
    end

    test "a tag not equal to a value finds the points that lack the tag", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "o v=9,w=90 6000", database: "db")

      assert {:ok, rows} = iql(conn, "SELECT v FROM o WHERE k != 'a'")
      assert Enum.map(rows, & &1["v"]) === [2.0, 4.0, 9.0]
    end

    test "a row without the tag has no key for it, not an empty string", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "o v=9,w=90 6000", database: "db")

      assert {:ok, [row]} = iql(conn, "SELECT * FROM o WHERE k = ''")
      refute Map.has_key?(row, "k")

      assert {:ok, rows} = iql(conn, "SELECT * FROM o")
      assert length(rows) === 6
      refute Enum.any?(rows, &(&1["k"] === ""))
    end

    test "SHOW MEASUREMENTS lists the measurements by name", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "zz v=1 1\naa v=1 1\nmm v=1 1", database: "db")
      assert {:ok, rows} = iql(conn, "SHOW MEASUREMENTS")
      assert Enum.map(rows, & &1["name"]) === ["aa", "mm", "o", "zz"]
    end
  end

  # ---------------------------------------------------------------------------
  # Flux through the double
  # ---------------------------------------------------------------------------

  describe "query_flux/3 — range" do
    test "an integer second count that does not fit wraps in 64-bit nanoseconds" do
      conn = v2_conn()
      assert {:ok, :written} = Local.write(conn, "m v=1 5", database: "b")

      assert {:ok, [row]} = flux_range(conn, "start: 0, stop: 99999999999999")
      assert row["_start"] === ~U[1970-01-01 00:00:00.000000Z]
      assert row["_stop"] === ~U[1976-05-08 04:06:59.520689Z]

      assert {:ok, [row]} = flux_range(conn, "start: 0, stop: 9223372036")
      assert row["_stop"] === ~U[2262-04-11 23:47:16.000000Z]

      # The stop wraps below the start, but a range is judged on the seconds.
      assert {:ok, []} = flux_range(conn, "start: 0, stop: 18446744073")
    end

    test "a negative duration reaches back from now, a positive one forward" do
      conn = v2_conn()
      now = System.os_time(:nanosecond)
      later = now + 86_400_000_000_000

      assert {:ok, :written} = Local.write(conn, "m v=1 #{now}\nm v=2 #{later}", database: "b")

      assert {:ok, [row]} = flux_range(conn, "start: -1h, stop: now()")
      assert {row["_value"], DateTime.diff(row["_stop"], row["_start"], :second)} === {1.0, 3_600}

      assert {:ok, [row]} = flux_range(conn, "start: now(), stop: 1w")

      assert {row["_value"], DateTime.diff(row["_stop"], row["_start"], :second)} ===
               {2.0, 604_800}
    end

    test "a duration that does not fit wraps to the engine's value" do
      conn = v2_conn()
      assert {:ok, :written} = Local.write(conn, "m v=1 5", database: "b")

      assert {:ok, [row]} = flux_range(conn, "start: -99999999999w, stop: now()")

      stop_ns = DateTime.to_unix(row["_stop"], :nanosecond)
      week = 604_800_000_000_000

      # `now` carries nanoseconds a row's time does not, which can move the
      # microsecond of the wrapped start by one.
      candidates =
        for extra <- [0, 999],
            do: DateTime.from_unix!(wrap64(stop_ns + extra - 99_999_999_999 * week), :nanosecond)

      assert Enum.any?(candidates, &(DateTime.truncate(&1, :microsecond) === row["_start"]))
      assert row["_start"].year === 1810
    end

    test "an RFC3339 time that does not fit wraps" do
      conn = v2_conn()
      assert {:ok, :written} = Local.write(conn, "m v=1 5", database: "b")
      assert {:ok, rows} = flux_range(conn, "start: 0001-01-01T00:00:00Z, stop: now()")

      assert Enum.map(rows, & &1["_start"]) === [~U[1754-08-30 22:43:41.128654Z]]
    end

    test "a range with no time in it is the engine's plan error" do
      conn = v2_conn()

      for args <- [
            "start: 5, stop: 3",
            "start: 0, stop: 0",
            "start: 0, stop: -1",
            "start: -1h, stop: -2h",
            "start: now()",
            "start: 1970-01-01T00:00:10Z, stop: 1970-01-01T00:00:05Z",
            "start: 3000000000, stop: 1",
            "start: 0, stop: 9223372036854775807",
            "start: 0, stop: 2262-04-12T00:00:00Z",
            "start: 18446744073, stop: 18446744070"
          ] do
        assert error_body(flux_range(conn, args)) === @empty_range, args
      end

      # Judged on the seconds as Go counts them, these have a range.
      for args <- [
            "start: 0, stop: 18446744073",
            "start: 9223372037, stop: 9223372038",
            "start: 18446744073, stop: 18446744075"
          ] do
        assert {:ok, []} = flux_range(conn, args), args
      end
    end
  end

  describe "query_flux/3 — stages" do
    test "rows of a table are in the stored nanosecond order: first, last, limit and the rows" do
      conn = v2_conn()

      assert {:ok, :written} =
               Local.write(conn, "m,t=a v=1i 1001\nm,t=a v=2i 1000", database: "b")

      assert {:ok, rows} = flux_all(conn, "")
      assert Enum.map(rows, & &1["_value"]) === [2, 1]

      for {stage, value} <- [{"first()", 2}, {"last()", 1}, {"limit(n: 1)", 2}] do
        assert {:ok, [row]} = flux_all(conn, "|> " <> stage)
        assert row["_value"] === value, stage
      end

      assert {:ok, [row]} = flux_all(conn, "|> limit(n: 1, offset: 1)")
      assert row["_value"] === 1
    end

    test "sort and group are refused by name" do
      conn = v2_conn()

      for stage <- ["sort()", "group()"] do
        assert error_body(flux_all(conn, "|> " <> stage)) === %{
                 "code" => "invalid",
                 "message" => "Client.Local: unsupported Flux function: #{stage}"
               }
      end
    end

    test "a filter on _measurement reads only those measurements" do
      conn = v2_conn()
      assert {:ok, :written} = Local.write(conn, "a v=1 1\nb v=2 2\nc v=3 3", database: "b")

      reads = fn filter ->
        assert {:ok, rows} = flux_all(conn, "|> filter(fn: (r) => #{filter})")
        Enum.map(rows, &{&1["_measurement"], &1["_value"]})
      end

      assert reads.(~s|r._measurement == "a"|) === [{"a", 1.0}]

      assert reads.(~s|r._measurement == "a" or r._measurement == "c"|) === [
               {"a", 1.0},
               {"c", 3.0}
             ]

      assert reads.(~s|r._measurement == "a" and r._measurement == "b"|) === []
      assert reads.(~s|r._measurement != "a"|) === [{"b", 2.0}, {"c", 3.0}]
      assert reads.(~s|not (r._measurement == "a")|) === [{"b", 2.0}, {"c", 3.0}]

      assert reads.(~s|r._measurement == "a" or r._field == "v"|) === [
               {"a", 1.0},
               {"b", 2.0},
               {"c", 3.0}
             ]

      assert reads.(~s|r._measurement == "nope"|) === []
    end

    test "a measurement InfluxDB 2 accepts and never returns is not returned" do
      conn = v2_conn()

      assert {:ok, :written} =
               Local.write(conn, ~S"gone\\,x v=1i 1" <> "\n" <> ~S"here\,x v=2i 2", database: "b")

      assert {:ok, rows} = flux_all(conn, "")
      assert Enum.map(rows, &{&1["_measurement"], &1["_value"]}) === [{"here,x", 2}]
    end
  end

  # ---------------------------------------------------------------------------
  # Writes and buckets through the double
  # ---------------------------------------------------------------------------

  describe "write/3 — InfluxDB 2 shard groups" do
    # A bucket that keeps three hours has hour-long groups, one that keeps
    # three days day-long ones. Each gets `v` as a float in the group of
    # `first`; `second` is two hours on, in the same group only for the
    # daily bucket. Every time is before now whatever the time of day: the
    # hourly pair lies in the two hours before the current one, the daily
    # pair in the day before the current one.
    setup do
      conn = v2_conn([])
      :ok = Local.create_bucket(conn, "hourly", retention: 10_800)
      :ok = Local.create_bucket(conn, "daily", retention: 259_200)

      now = Store.now_ns()
      hour = Integer.floor_div(now, @hour_ns) * @hour_ns
      yesterday = Integer.floor_div(now, 24 * @hour_ns) * 24 * @hour_ns - 24 * @hour_ns

      times = %{
        "hourly" => {hour - 2 * @hour_ns + 5 * @minute_ns, hour - 5 * @minute_ns},
        "daily" => {yesterday + @hour_ns, yesterday + 3 * @hour_ns}
      }

      for {bucket, {first, _second}} <- times do
        assert {:ok, :written} = Local.write(conn, "m v=1.5 #{first}", database: bucket)
      end

      {:ok, conn: conn, times: times}
    end

    test "a bucket of hour-long groups reports the first group's drop, counting its own",
         %{conn: conn, times: %{"hourly" => {first, second}}} do
      payload = "m v=1i #{first}\nm time=1 #{second}"

      assert error_body(Local.write(conn, payload, database: "hourly")) ===
               drop_body(@drop_conflict <> "1")
    end

    test "a bucket of day-long groups counts both drops of the one group",
         %{conn: conn, times: %{"daily" => {first, second}}} do
      payload = "m v=1i #{first}\nm time=1 #{second}"

      assert error_body(Local.write(conn, payload, database: "daily")) ===
               drop_body(@drop_conflict <> "2")
    end

    test "the earliest hour-long group speaks whatever order the payload gives them in",
         %{conn: conn, times: %{"hourly" => {first, second}}} do
      payload = "m time=1 #{second}\nm v=1i #{first}\nm time=1 #{first}"

      assert error_body(Local.write(conn, payload, database: "hourly")) ===
               drop_body(@drop_conflict <> "2")
    end

    test "in one day-long group the first drop in the payload speaks, counting all three",
         %{conn: conn, times: %{"daily" => {first, second}}} do
      payload = "m time=1 #{second}\nm v=1i #{first}\nm time=1 #{first}"

      assert error_body(Local.write(conn, payload, database: "daily")) ===
               drop_body(@drop_invalid <> "3")
    end

    test "a payload of thousands of groups is written group by group" do
      conn = v2_conn(["weekly"])
      assert {:ok, :written} = Local.write(conn, "m v=1.5 5", database: "weekly")

      payload = Enum.map_join(0..2_999, "\n", &"m v=1i #{&1 * 604_800_000_000_000 + 7}")

      assert error_body(Local.write(conn, payload, database: "weekly")) ===
               drop_body(@drop_conflict <> "1")
    end
  end

  describe "write/3 — InfluxDB 2 retention" do
    setup do
      conn = v2_conn([])
      :ok = Local.create_bucket(conn, "short", retention: 7200)
      :ok = Local.create_bucket(conn, "forever")
      {:ok, conn: conn, now: Store.now_ns()}
    end

    test "a bucket that keeps everything accepts a point of any age", %{conn: conn} do
      assert {:ok, :written} = Local.write(conn, "m v=1i 5", database: "forever")
    end

    test "a point older than the retention is the engine's 422, naming it", ctx do
      %{conn: conn} = ctx
      body = error_body(Local.write(conn, "m v=1i 1672790400000000000", database: "short"))

      assert {masked, _bounds} = masked_retention(conn, "short", body)

      assert masked ===
               "failure writing points to database: partial write: dropped 1 points outside " <>
                 "retention policy of duration 2h0m0s - oldest point m at 2023-01-04T00:00:00Z " <>
                 "dropped because it violates a Retention Policy Lower Bound at BOUND, " <>
                 "newest point m at 2023-01-04T00:00:00Z dropped because it violates a " <>
                 "Retention Policy Lower Bound at BOUND dropped=1 for database: ID " <>
                 "for retention policy: autogen"
    end

    test "the lower bound is the retention before now", %{conn: conn} do
      first = Store.now_ns()
      body = error_body(Local.write(conn, "m v=1i 5", database: "short"))
      last = Store.now_ns()

      assert {_masked, [bound, same]} = masked_retention(conn, "short", body)
      assert bound === same

      # Printed to the microsecond at most, so it is compared as one.
      assert {:ok, bound, 0} = DateTime.from_iso8601(bound)
      printed = DateTime.to_unix(bound, :microsecond)
      assert printed >= Integer.floor_div(first - 7200 * 1_000_000_000, 1_000)
      assert printed <= Integer.floor_div(last - 7200 * 1_000_000_000, 1_000)
    end

    test "the oldest and the newest dropped point are named by series key and time",
         %{conn: conn} do
      payload =
        "m1,t=a v=1i 1672790400123456789\n" <>
          "m2,u=c,t=b v=1i 1672790400000000001\n" <>
          "m3 v=1i 1672790400123456000"

      body = error_body(Local.write(conn, payload, database: "short"))
      assert {masked, _bounds} = masked_retention(conn, "short", body)

      assert masked =~ "dropped 3 points"
      assert masked =~ "oldest point m2,t=b,u=c at 2023-01-04T00:00:00.000000001Z dropped"
      assert masked =~ "newest point m1,t=a at 2023-01-04T00:00:00.123456789Z dropped"
      assert masked =~ "dropped=3 for database"
    end

    test "on a tie the first point of the payload is both the oldest and the newest",
         %{conn: conn} do
      body =
        error_body(
          Local.write(conn, "m1 v=1i 1672790400000000000\nm2 v=1i 1672790400000000000",
            database: "short"
          )
        )

      assert {masked, _bounds} = masked_retention(conn, "short", body)
      assert masked =~ "oldest point m1 at 2023-01-04T00:00:00Z dropped"
      assert masked =~ "newest point m1 at 2023-01-04T00:00:00Z dropped"
    end

    test "a series key is escaped as line protocol escapes it", %{conn: conn} do
      payload = ~S"m\ x\,y,b\ k\=1=v\,2\ 3,a=z v=1i 1672790400000000000"
      body = error_body(Local.write(conn, payload, database: "short"))
      assert {masked, _bounds} = masked_retention(conn, "short", body)

      key = ~S"m\ x\,y,a=z,b\ k\=1=v\,2\ 3"
      assert masked =~ "oldest point #{key} at 2023-01-04T00:00:00Z dropped"
    end

    test "the duration is Go's, in hours", %{conn: conn} do
      :ok = Local.create_bucket(conn, "odd", retention: 90_061)
      body = error_body(Local.write(conn, "m v=1i 5", database: "odd"))
      assert {masked, _bounds} = masked_retention(conn, "odd", body)
      assert masked =~ "outside retention policy of duration 25h1m1s - "
    end

    test "the other points of the payload are written", %{conn: conn, now: now} do
      assert {:error, %{status: 422}} =
               Local.write(conn, "m v=1i 5\nm v=2i #{now - 60_000_000_000}", database: "short")

      assert {:ok, rows} =
               Local.query_flux(conn, ~s|from(bucket: "short") \|> range(start: -3h, stop: 1h)|)

      assert Enum.map(rows, & &1["_value"]) === [2]
    end

    test "a point older than the retention registers no field type", %{conn: conn, now: now} do
      assert {:error, %{status: 422}} = Local.write(conn, "m v=2.5 5", database: "short")
      assert {:ok, :written} = Local.write(conn, "m v=1i #{now}", database: "short")
    end

    test "a point older than the retention is dropped before its fields are judged",
         %{conn: conn} do
      body = error_body(Local.write(conn, "m time=1 5", database: "short"))
      assert {masked, _bounds} = masked_retention(conn, "short", body)
      assert masked =~ "partial write: dropped 1 points outside retention policy"
    end

    test "a group's drop is reported instead of the retention drops", %{conn: conn, now: now} do
      assert {:ok, :written} = Local.write(conn, "m v=1i #{now}", database: "short")

      payload = "m v=1i 5\nm v=2.5 #{now + 1}"

      assert error_body(Local.write(conn, payload, database: "short")) ===
               drop_body(
                 "failure writing points to database: partial write: field type conflict: " <>
                   ~s|input field "v" on measurement "m" is type float, | <>
                   "already exists as type integer dropped=1"
               )
    end
  end

  describe "delete_bucket/2 — the bucket's data goes with it" do
    test "another bucket keeps its points and its field types" do
      conn = v2_conn(["b", "other"])
      assert {:ok, :written} = Local.write(conn, "m v=1i 5", database: "other")
      assert :ok = Local.delete_bucket(conn, "b")

      assert {:error, %{status: 422}} = Local.write(conn, "m v=1.5 5", database: "other")

      # `_stop` is the clock's reading; the rest of the row is exact.
      assert {:ok, [row]} = Local.query_flux(conn, ~s|from(bucket: "other") \|> range(start: 0)|)

      assert Map.delete(row, "_stop") === %{
               "result" => "_result",
               "table" => 0,
               "_measurement" => "m",
               "_field" => "v",
               "_start" => ~U[1970-01-01 00:00:00.000000Z],
               "_time" => ~U[1970-01-01 00:00:00.000000Z],
               "_value" => 1
             }
    end

    test "the store holds nothing of the bucket" do
      table = Store.new([])
      Store.put_bucket(table, "b", %{retention: 0})
      Store.register_column(table, "b", "m", "v", "iox::column_type::field::integer")
      Store.store_points(table, "b", [stored("m", %{}, 1, 5)])
      Store.store_points(table, "b", [stored("m", %{}, 2, 5)])

      # The same series and time twice: one merged point, and the series
      # index and the duplicate marker hold something to be deleted.
      assert Store.points(table, "b", "m") ===
               [%{measurement: "m", tags: %{}, fields: %{"v" => 2}, timestamp: 5}]

      assert :ok = Store.delete_bucket(table, "b")

      assert Store.points(table, "b", "m") === []
      assert Store.column_kind(table, "b", "m", "v") === nil

      # A bucket made again under the name reads nothing back, and takes the
      # same series and time as a first write: one point, with only its own
      # fields, not merged with anything the deleted bucket held.
      Store.put_bucket(table, "b", %{retention: 0})
      assert Store.points(table, "b", "m") === []

      Store.store_points(table, "b", [%{stored("m", %{}, 3, 5) | fields: %{"w" => 3}}])

      assert Store.points(table, "b", "m") ===
               [%{measurement: "m", tags: %{}, fields: %{"w" => 3}, timestamp: 5}]
    end
  end

  describe "query_flux/3 — a field of another type in a later shard group" do
    test "a bucket of hour-long groups reads up to the first group of another type" do
      conn = v2_conn([])
      :ok = Local.create_bucket(conn, "hourly", retention: 10_800)
      hour = Integer.floor_div(Store.now_ns(), @hour_ns) * @hour_ns

      assert {:ok, :written} =
               Local.write(
                 conn,
                 "m v=1i #{hour - 2 * @hour_ns + 5 * @minute_ns}\n" <>
                   "m v=2.5 #{hour - @hour_ns + 5 * @minute_ns}\n" <>
                   "m v=3i #{hour}",
                 database: "hourly"
               )

      assert {:ok, rows} =
               Local.query_flux(conn, ~s|from(bucket: "hourly") \|> range(start: -3h, stop: 1h)|)

      assert Enum.map(rows, & &1["_value"]) === [1]
    end
  end

  describe "list_buckets/1" do
    test "a bucket's orgID is its org's and its id is stable across calls and connections" do
      {:ok, conn} = Local.start(profile: :v2, org: "acme")
      :ok = Local.create_bucket(conn, "one")
      :ok = Local.create_bucket(conn, "two", retention: 86_400)

      assert {:ok, [one, two]} = Local.list_buckets(conn)
      assert {:ok, [^one, ^two]} = Local.list_buckets(conn)

      assert two["orgID"] === one["orgID"]
      assert one["id"] != two["id"]

      # Another connection to the same org lists the same ids; another org does not.
      {:ok, same} = Local.start(profile: :v2, org: "acme")
      {:ok, other} = Local.start(profile: :v2, org: "other")
      :ok = Local.create_bucket(same, "one")
      :ok = Local.create_bucket(other, "one")

      # Created on another connection, so its time differs; its identity does not.
      assert {:ok, [same_one]} = Local.list_buckets(same)
      assert Map.take(same_one, ["orgID", "id"]) === Map.take(one, ["orgID", "id"])
      assert {:ok, [other_one]} = Local.list_buckets(other)
      refute other_one["orgID"] === one["orgID"]
    end

    test "creating a bucket again keeps its creation time" do
      conn = v2_conn([])
      :ok = Local.create_bucket(conn, "one")
      {:ok, [first]} = Local.list_buckets(conn)
      let_the_clock_move()
      :ok = Local.create_bucket(conn, "one")
      assert {:ok, [^first]} = Local.list_buckets(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # The store
  # ---------------------------------------------------------------------------

  describe "Store" do
    test "measurements are listed by name from the schema" do
      table = Store.new(["db"])
      for m <- ["zz", "aa", "mm"], do: Store.register_column(table, "db", m, "v", "t")
      Store.register_column(table, "other", "xx", "v", "t")
      for m <- ["zz", "aa"], do: Store.register_column(table, "db", m, "w", "t")

      assert Store.measurements(table, "db") === ["aa", "mm", "zz"]
      assert Store.measurements(table, "other") === ["xx"]
      assert Store.measurements(table, "none") === []
    end

    test "points_in_db reads the measurements it is asked for" do
      table = Store.new(["db"])

      for m <- ["a", "b", "c"], i <- 1..3 do
        Store.store_points(table, "db", [stored(m, %{}, i, i)])
      end

      assert table |> Store.points_in_db("db") |> length() === 9
      assert table |> Store.points_in_db("db", :all) |> length() === 9

      assert table |> Store.points_in_db("db", ["b", "a", "b"]) |> Enum.map(& &1.measurement) ===
               ["a", "a", "a", "b", "b", "b"]

      assert [] = Store.points_in_db(table, "db", [])
      assert [] = Store.points_in_db(table, "db", ["nope"])
      assert [] = Store.points_in_db(table, "db", [5])
    end

    test "a token is created whole; _admin and a taken name are :exists and spend no id" do
      table = Store.new([])
      build = fn id -> %{"id" => id, "name" => "t"} end
      token = fn id -> {:ok, %{"id" => id, "name" => "t"}} end

      assert Store.create_token(table, "a", build) === token.(1)
      assert :exists = Store.create_token(table, "a", build)
      assert :exists = Store.create_token(table, "_admin", build)
      assert Store.create_token(table, "b", build) === token.(2)
      assert :ok = Store.delete_token(table, "a")
      assert :error = Store.delete_token(table, "a")
      assert Store.create_token(table, "a", build) === token.(3)
    end

    test "concurrent creates of one name make one token and spend one id" do
      table = Store.new([])
      build = fn id -> %{"id" => id} end

      results = at_once(@tasks, fn _n -> Store.create_token(table, "same", build) end)

      assert Enum.filter(results, &match?({:ok, _token}, &1)) === [ok: %{"id" => 1}]
      assert Enum.count(results, &(&1 === :exists)) === @tasks - 1
      assert Store.create_token(table, "next", build) === {:ok, %{"id" => 2}}
    end

    test "concurrent creates of different names give each its own id, in a row" do
      table = Store.new([])

      ids =
        at_once(@tasks, fn n ->
          {:ok, %{"id" => id}} = Store.create_token(table, "t#{n}", &%{"id" => &1})
          id
        end)

      assert Enum.sort(ids) === Enum.to_list(1..@tasks)
    end

    test "a token deleted while it is being created ends up as one of the two orders left it" do
      for round <- 1..16 do
        table = Store.new([])
        name = "t#{round}"
        build = &%{"id" => &1}

        [created, deleted] =
          at_once(2, fn
            1 -> Store.create_token(table, name, build)
            2 -> Store.delete_token(table, name)
          end)

        # Delete first: nothing to delete, and the token stays. Create first:
        # the delete removes it, and a second delete finds nothing.
        case {created, deleted} do
          {{:ok, %{"id" => 1}}, :error} -> assert :ok = Store.delete_token(table, name)
          {{:ok, %{"id" => 1}}, :ok} -> assert :error = Store.delete_token(table, name)
        end

        assert Store.create_token(table, "next", build) === {:ok, %{"id" => 2}}
      end
    end

    test "a deleted token's name is free again, and the delete is not undone" do
      table = Store.new([])
      build = &%{"id" => &1}

      assert Store.create_token(table, "t", build) === {:ok, %{"id" => 1}}
      assert :ok = Store.delete_token(table, "t")
      assert :error = Store.delete_token(table, "t")
      assert Store.create_token(table, "t", build) === {:ok, %{"id" => 2}}
    end

    test "concurrent creates of databases cannot pass the limit" do
      table = Store.new([])
      check = fn existing -> if Enum.count(existing) >= 5, do: {:error, :limit}, else: :ok end

      results = at_once(@tasks, fn n -> Store.create_database(table, "db#{n}", check) end)

      assert Enum.count(results, &(&1 === :ok)) === 5
      assert Enum.count(results, &(&1 === {:error, :limit})) === @tasks - 5
      assert table |> Store.databases() |> MapSet.size() === 5
    end

    test "a lock holder that is killed does not block the next creator" do
      table = Store.new([])
      parent = self()

      holder =
        spawn(fn ->
          Store.create_database(table, "held", fn _existing ->
            send(parent, :holding)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :holding, 5_000

      waiter = Task.async(fn -> Store.create_database(table, "next", fn _existing -> :ok end) end)
      Process.exit(holder, :kill)

      assert Task.await(waiter, 5_000) === :ok
      assert Store.database?(table, "next")
      refute Store.database?(table, "held")
    end

    test "a database that exists is :ok at the limit, and a refused one is not created" do
      table = Store.new(["a", "b"])
      full = fn _existing -> {:error, :limit} end

      assert :ok = Store.create_database(table, "a", full)
      assert {:error, :limit} = Store.create_database(table, "c", full)
      refute Store.database?(table, "c")
    end

    test "points of one payload at one series and time are one point, the last write winning" do
      table = Store.new(["db"])
      tags = %{"h" => "x"}

      Store.store_points(table, "db", [
        stored("m", tags, 1, 5),
        stored("m", %{"h" => "y"}, 7, 5),
        stored("m", tags, 2, 5)
      ])

      assert Store.points(table, "db", "m") === [
               stored("m", tags, 2, 5),
               stored("m", %{"h" => "y"}, 7, 5)
             ]
    end

    test "fields of points at one series and time merge across payloads" do
      table = Store.new(["db"])
      tags = %{"h" => "x"}
      first = %{stored("m", tags, 1, 5) | fields: %{"a" => 1, "b" => 1}}
      second = %{stored("m", tags, 1, 5) | fields: %{"b" => 2, "c" => 2}}

      Store.store_points(table, "db", [first, stored("m", tags, 9, 6)])
      Store.store_points(table, "db", [second, stored("m", tags, 8, 7)])

      assert [merged, _six, _seven] = Store.points(table, "db", "m")
      assert merged.fields === %{"a" => 1, "b" => 2, "c" => 2}
    end

    test "a payload with no repeat stores every point, and a later repeat adds none" do
      table = Store.new(["db"])
      Store.store_points(table, "db", for(t <- 1..5, do: stored("m", %{}, t, t)))

      assert table |> Store.points("db", "m") |> Enum.map(& &1.timestamp) === [1, 2, 3, 4, 5]

      Store.store_points(table, "db", [stored("m", %{}, 9, 3)])

      assert table |> Store.points("db", "m") |> Enum.map(&{&1.timestamp, &1.fields}) ===
               [
                 {1, %{"v" => 1}},
                 {2, %{"v" => 2}},
                 {3, %{"v" => 9}},
                 {4, %{"v" => 4}},
                 {5, %{"v" => 5}}
               ]
    end

    test "a point without a timestamp is stamped, and stored" do
      table = Store.new(["db"])
      before = Store.now_ns()
      assert Store.store_points(table, "db", [stored("m", %{}, 1, nil)])

      assert [%{timestamp: stamp}] = Store.points(table, "db", "m")
      assert stamp >= before
    end

    test "writers of the same payload at once leave one point per series and time" do
      table = Store.new(["db"])
      points = for t <- 1..300, do: stored("m", %{"h" => "x"}, t, t)

      at_once(@tasks, fn _n -> Store.store_points(table, "db", points) end)

      assert Store.points(table, "db", "m") === points
    end

    test "points written again after a delete are not merged with the deleted ones" do
      table = Store.new(["db"])
      Store.register_column(table, "db", "m", "v", "iox::column_type::field::integer")
      tags = %{"h" => "x"}

      Store.store_points(table, "db", [stored("m", tags, 1, 5)])
      Store.store_points(table, "db", [stored("m", tags, 2, 5)])
      assert Store.points(table, "db", "m") === [stored("m", tags, 2, 5)]

      assert Store.delete_points(table, "db", "m", fn _point -> true end) === 1
      assert Store.points(table, "db", "m") === []

      Store.store_points(table, "db", [stored("m", tags, 3, 5)])
      assert Store.points(table, "db", "m") === [stored("m", tags, 3, 5)]
    end

    test "writers of other series survive a concurrent delete exactly" do
      for _round <- 1..8 do
        table = Store.new(["db"])
        Store.store_points(table, "db", [stored("m", %{"s" => "old"}, 0, 5)])

        # Writers 1..@tasks and, last, the deleter.
        results =
          at_once(@tasks + 1, fn
            n when n <= @tasks ->
              Store.store_points(table, "db", [stored("m", %{"s" => "new#{n}"}, n, 5)])

            _deleter ->
              Store.delete_points(table, "db", "m", &(&1.tags === %{"s" => "old"}))
          end)

        assert List.last(results) === 1

        assert table |> Store.points("db", "m") |> Enum.sort_by(& &1.fields["v"]) ===
                 for(n <- 1..@tasks, do: stored("m", %{"s" => "new#{n}"}, n, 5))
      end
    end
  end

  describe "Local — concurrency through the double" do
    test "first writes to new databases stop at Core's five" do
      {:ok, conn} = Local.start(profile: :v3_core)

      results =
        at_once(@tasks, fn n -> Local.write(conn, "m v=1 #{n}", database: "limit#{n}") end)

      assert Enum.count(results, &(&1 === {:ok, :written})) === 5
      assert Enum.count(results, &match?({:error, %{status: 422}}, &1)) === @tasks - 5

      assert {:ok, listed} = Local.list_databases(conn)
      assert length(listed) === 6
    end

    test "tokens created at once get the ids 1 up, each its own" do
      conn = v3_conn([])

      ids =
        at_once(@tasks, fn n ->
          assert {:ok, %{"id" => id}} = Local.create_token(conn, "tok#{n}")
          id
        end)

      assert Enum.sort(ids) === Enum.to_list(1..@tasks)
    end

    test "a taken token name is a 409, and a deleted one comes back with the next id" do
      conn = v3_conn([])
      # The secret, its hash and the creation time are generated: `public/1`
      # checks their shape and drops them.
      assert conn |> Local.create_token("tok1") |> TokenShape.public() ===
               {:ok, %{"id" => 1, "name" => "tok1", "expiry" => nil}}

      assert {:error, %{status: 409}} = Local.create_token(conn, "tok1")
      assert :ok = Local.delete_token(conn, "tok1")

      assert conn |> Local.create_token("tok1") |> TokenShape.public() ===
               {:ok, %{"id" => 2, "name" => "tok1", "expiry" => nil}}
    end

    test "writers of one series at once leave one point per time" do
      conn = v3_conn()
      payload = Enum.map_join(1..500, "\n", &"m,h=a v=#{&1} #{&1}")

      results = at_once(@tasks, fn _n -> Local.write(conn, payload, database: "db") end)
      assert Enum.all?(results, &(&1 === {:ok, :written}))

      assert {:ok, rows} = iql(conn, "SELECT v FROM m")
      assert Enum.map(rows, & &1["v"]) === Enum.map(1..500, &(&1 * 1.0))
    end
  end

  describe "Store — the lock is not re-entrant" do
    test "a holder that takes its own lock again raises instead of spinning" do
      table = Store.new([])

      assert_raise RuntimeError, ~r/databases lock is already held by this process/, fn ->
        Store.create_database(table, "outer", fn _databases ->
          Store.create_database(table, "inner", fn _databases -> :ok end)
        end)
      end

      assert_raise RuntimeError, ~r/tokens lock is already held by this process/, fn ->
        Store.create_token(table, "outer", fn _id ->
          Store.create_token(table, "inner", fn id -> %{"id" => id} end)
        end)
      end

      # the raise released the locks: neither resource is stuck, nor half made
      refute Store.database?(table, "outer")
      assert :ok = Store.create_database(table, "later", fn _databases -> :ok end)
      assert {:ok, %{"id" => 1}} = Store.create_token(table, "later", &%{"id" => &1})
    end

    test "another process waits for the holder instead of raising" do
      table = Store.new([])
      parent = self()

      holder =
        Task.async(fn ->
          Store.create_database(table, "slow", fn _databases ->
            send(parent, :holding)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :holding, 5_000

      waiter =
        Task.async(fn -> Store.create_database(table, "other", fn _databases -> :ok end) end)

      refute Task.yield(waiter, 50)

      send(holder.pid, :release)
      assert Task.await(holder) === :ok
      assert Task.await(waiter) === :ok
      assert Store.databases(table) === MapSet.new(["slow", "other"])
    end
  end
end
