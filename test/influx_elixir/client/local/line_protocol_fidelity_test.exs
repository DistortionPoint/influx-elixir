defmodule InfluxElixir.Client.Local.LineProtocolFidelityTest do
  @moduledoc """
  The line protocol grammar of both engines, parsed by `Client.Local`'s own
  parser. Every expectation was read from InfluxDB 3 Core or InfluxDB 2.7; the
  facts a real engine can be asked in the same words are in
  `InfluxElixir.Contract.InfluxQLFluxLP`.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Client.Local.LineProtocolParser

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

  defp iql(conn, statement), do: Local.query_influxql(conn, statement, database: "db")

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
end
