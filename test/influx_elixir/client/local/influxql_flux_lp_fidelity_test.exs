defmodule InfluxElixir.Client.Local.InfluxQLFluxLPFidelityTest do
  @moduledoc """
  Unit tests for the line protocol grammar of both engines, InfluxQL's
  `WHERE`, time and `LIMIT`, Flux's `range` and the store's atomicity.
  Every expectation was read from InfluxDB 3 Core or InfluxDB 2.7; the
  same facts, through a client, are in
  `InfluxElixir.Contract.InfluxQLFluxLP`.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Client.Local.{Flux, InfluxQL, LineProtocolParser, Store}

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

  # ---------------------------------------------------------------------------
  # Line protocol, InfluxDB 3
  # ---------------------------------------------------------------------------

  @trailing "Could not parse entire line. Found trailing content: "
  @no_fields "No fields were provided"
  @backslash "Measurements, tag keys and values, and field keys may not end with a backslash"

  describe "InfluxDB 3 line protocol — the engine's errors" do
    test "the lines the report named" do
      assert v3_error("lp v=1 100 200") == @trailing <> "`200`"
      assert v3_error("lp v=.5 1") == @no_fields
      assert v3_error("lp v=5. 2") == @trailing <> "`. 2`"
    end

    test "the engine quotes ten characters of what is left, and dots for the rest" do
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
        assert v3_error(line) == message, line
      end

      # "Expected at least one space character" quotes all of it.
      assert v3_error("zz\tabcdefghijklmnop v=1") ==
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
        assert v3_error("zz v=#{value}") == message, value
      end
    end

    test "what is not a value at all fails the field" do
      for value <-
            ~w(.5 -.5 +5 +1i .5i e1 NaN inf -inf Infinity --1 .e3 .5u x) ++ ["\"abc", "abc\""] do
        assert v3_error("zz v=#{value}") == @no_fields, value
      end
    end

    test "a boolean is the longest of true, True, TRUE, t, T and the false forms" do
      for {value, message} <- [
            {"true1", @trailing <> "`1`"},
            {"tRUE", @trailing <> "`RUE`"},
            {"TrUe", @trailing <> "`rUe`"},
            {"tru", @trailing <> "`ru`"}
          ] do
        assert v3_error("zz v=#{value}") == message, value
      end

      assert %{fields: %{"a" => true, "b" => false, "c" => true, "d" => false}} =
               v3_point("zz a=T,b=f,c=True,d=FALSE")
    end

    test "a string value ends at its closing quote" do
      assert v3_error(~s|zz v="a"b"|) == @trailing <> ~s|`b"`|
      assert %{fields: %{"v" => ~s|a"b|}} = v3_point(~S|zz v="a\"b"|)
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
        assert v3_error("zz v=1#{tail}") == message, tail
      end

      for tail <- [" 5 ", " 5  ", "  5", " -5"] do
        assert %{fields: %{"v" => 1.0}} = v3_point("zz v=1#{tail}")
      end
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
        assert v3_error(line) == message, line
      end
    end

    test "a first field that fails is no fields at all" do
      for line <- ["zz =1", "zz v", "zz v= 1", "zz v =1", "zz ", "zz   ", "zz 5"] do
        assert v3_error(line) == @no_fields, line
      end

      assert v3_error("zz \"a b\"=1") == @no_fields
      assert v3_error(~s|zz a=1,"b c"=2|) == @trailing <> ~S|`"b c"=2`|
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
            {"zz,t=1", "Expected at least one space character, got end of input"},
            {"zz,t=1,u=2", "Expected at least one space character, got end of input"},
            {"justmeasurement", "Expected at least one space character, got end of input"},
            {"zz,t=1 ", @no_fields},
            {",t=1 v=1", "Invalid measurement was provided"},
            {",", "Invalid measurement was provided"},
            {"m\"x y\" v=1", @no_fields},
            {~s|zz,t="a b" v=1|, @no_fields}
          ] do
        assert v3_error(line) == message, line
      end
    end

    test "a tag key may start with a comma or hold one; a tag value may hold an =" do
      assert %{tags: %{",t" => "1"}} = v3_point("zz,,t=1 v=1")
      assert %{tags: %{"t,u" => "1"}} = v3_point("zz,t,u=1 v=1")
      assert %{tags: %{",u" => "2", "t" => "1"}} = v3_point("zz,t=1,,u=2 v=1")
      assert %{tags: %{"t" => "a=b"}} = v3_point("zz,t=a=b v=1")
      assert %{tags: %{"t" => "=b"}} = v3_point("zz,t==b v=1")
      assert %{tags: %{"t" => "1"}} = v3_point("zz,t=1,t=1 v=1")
    end

    test "a field key may hold commas and quotes; a trailing comma is accepted" do
      assert %{fields: %{"a,b" => 1.0}} = v3_point("zz a,b=1 5")
      assert %{fields: %{"w,x" => 2.0, "v" => 1.0}} = v3_point("zz v=1,w,x=2 5")
      assert %{fields: %{~s|"k"| => 1.0}} = v3_point(~s|zz "k"=1 5|)
      assert %{fields: %{"v" => 1.0}, timestamp: 5} = v3_point("zz v=1, 5")
      assert %{fields: %{"v" => 1.0, ",w" => 2.0}} = v3_point("zz v=1,,w=2")
      assert %{fields: %{"a b" => 1.0}} = v3_point(~S|zz a\ b=1|)
    end

    test "numbers: the forms the engine reads and their types" do
      assert %{fields: %{"v" => 1500.0}} = v3_point("zz v=1.5e3")
      assert %{fields: %{"v" => 1000.0}} = v3_point("zz v=1E+3")
      assert %{fields: %{"v" => 0.0015}} = v3_point("zz v=1.5E-3")
      assert %{fields: %{"v" => 7.0}} = v3_point("zz v=007")

      assert %{fields: %{"v" => 9_223_372_036_854_775_807}} =
               v3_point("zz v=9223372036854775807i")

      assert %{fields: %{"v" => {:uint, 1}}} = v3_point("zz v=1u")
      assert %{timestamp: -5} = v3_point("zz v=1 -5")
    end

    test "a number outside what its type holds is its own error" do
      assert v3_error("zz v=9223372036854775808i") ==
               "Unable to parse integer value `9223372036854775808`"

      assert v3_error("zz v=18446744073709551616u") ==
               "Unable to parse unsigned integer value `18446744073709551616`"

      assert v3_error("zz v=1e999") ==
               "Client.Local: the float 1e999 is outside what Elixir can hold"
    end

    test "a field named twice, or also a tag: the first the line meets wins" do
      assert v3_error("zz v=1,v=2 5") ==
               "invalid line protocol - multiple instances of 'v' field found"

      assert v3_error("zz,t=1 a=1,a=2,t=3") ==
               "invalid line protocol - multiple instances of 'a' field found"

      assert v3_error("zz,t=1 t=3,a=1,a=2") ==
               "invalid column type for column 't', expected iox::column_type::tag, " <>
                 "got iox::column_type::field::float"

      # A parse error comes before either.
      assert v3_error("zz v=1,v=2 abc") == @trailing <> "` abc`"
    end

    test "a name that ends in a backslash is refused wherever it ends" do
      for line <- [
            ~S"zz\\ v=1i 5",
            ~S"zz\\",
            ~S"zz,t\\ v=1i 5",
            ~S"zz,t\\",
            ~S"zz,t=a\\",
            ~S"zz,t=a\\ ",
            ~S"zz,t=a\\ v=1i 5",
            ~S"zz,t\\=1 v=1i",
            ~S"zz,t=\\ v=1i",
            ~S"zz v\\ =1i 5",
            ~S"zz v\\",
            ~S"zz v=1i,w\\ x=1i",
            ~S"zz v=1i,w\\=1i",
            ~S"zz v\\=1i 5"
          ] do
        assert v3_error(line) == @backslash, line
      end

      # An escaped separator is part of the name.
      assert %{tags: %{"t,u" => "1"}} = v3_point(~S"zz,t\,u=1 v=1i 5")
      assert %{measurement: "z z"} = v3_point(~S"z\ z v=1i 5")
      assert %{measurement: "z,z"} = v3_point(~S"z\,z v=1i 5")
    end

    test "blank lines and comments are skipped after leading blanks" do
      assert {:ok, [{:ok, %{measurement: "m"}, 4, _line}]} =
               LineProtocolParser.parse_lines(
                 "\n  # a comment\n\t \n  m v=1\n",
                 :nanosecond,
                 :v3
               )

      assert {:error, %{body: "incoming write was empty"}} =
               LineProtocolParser.parse_lines(" # only a comment", :nanosecond, :v3)
    end
  end

  # ---------------------------------------------------------------------------
  # Line protocol, InfluxDB 2
  # ---------------------------------------------------------------------------

  describe "InfluxDB 2 line protocol — the Go parser's errors" do
    test "the lines the report named" do
      assert v2_error("this is not line protocol!!") ==
               {"this is not line protocol!!", "invalid field format"}

      assert v2_error("m v=") == {"m v=", "missing field value"}
      assert v2_error("m n=1i\r") == {"m n=1i\r", "invalid number"}

      assert {:ok, [{:error, %{error_message: "invalid number", line: "m n=1i\r"}}]} =
               LineProtocolParser.parse_lines("m n=1i\r\n", :nanosecond, :v2)
    end

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
        assert v2_error(line) == {line, reason}, line
      end
    end

    test "an escape is judged by the byte before it" do
      # `\\,` is not a separator: the measurement keeps both, minus the escape of the comma.
      assert %{measurement: ~S"bs\,t=a", tags: %{}} = v2_point(~S"bs\\,t=a v=1i 1")
      assert %{measurement: "bs,t=a"} = v2_point(~S"bs\,t=a v=1i 1")
      assert v2_error(~S"zq\\ v=1i 5") == {~S"zq\\ v=1i 5", "invalid field format"}
      assert v2_error(~S"zq,t=a\\ v=1i 5") == {~S"zq,t=a\\ v=1i 5", "invalid tag format"}
      assert v2_error(~S"zq,t\\ v=1i 5") == {~S"zq,t\\ v=1i 5", "invalid field format"}
      assert v2_error(~S"zq,t\\=1 v=1i") == {~S"zq,t\\=1 v=1i", "missing tag value"}
      assert v2_error(~S"zq,t=\\ v=1i") == {~S"zq,t=\\ v=1i", "invalid tag format"}
      assert v2_error(~S"zq,t\\") == {~S"zq,t\\", "missing tag value"}
      assert v2_error(~S"zq\\") == {~S"zq\\", "missing fields"}
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
        assert v2_error(line) == {line, reason}, line
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
        assert v2_error(line) == {line, reason}, line
      end

      for tail <- ["", " 5", "  5", " 5 ", " 5   ", " -5"] do
        assert %{fields: %{"v" => 1.0}} = v2_point("zz v=1" <> tail)
      end
    end

    test "numbers outside what their type holds" do
      assert v2_error("zz v=9223372036854775808i") ==
               {"zz v=9223372036854775808i",
                "unable to parse integer 9223372036854775808: " <>
                  ~S|strconv.ParseInt: parsing "9223372036854775808": value out of range|}

      assert v2_error("zz v=-9223372036854775809i") ==
               {"zz v=-9223372036854775809i",
                "unable to parse integer -9223372036854775809: " <>
                  ~S|strconv.ParseInt: parsing "-9223372036854775809": value out of range|}

      assert v2_error("zz v=18446744073709551616u") ==
               {"zz v=18446744073709551616u",
                "unable to parse unsigned 18446744073709551616: " <>
                  ~S|strconv.ParseUint: parsing "18446744073709551616": value out of range|}
    end

    test "a field key that ends in a backslash is refused after the line scans" do
      for line <- [~S"zz v\\=1i 5", ~S"zz v=1i,w\\=1i"] do
        {quoted, reason} = v2_error(line)
        assert quoted == line
        assert reason =~ ~r/\Ainvalid value: field-key=.*\\\\=1i\z/
      end
    end

    test "floats like 5. and .5 are floats; a string takes its last byte off" do
      assert %{fields: %{"v" => 5.0}} = v2_point("zz v=5.")
      assert %{fields: %{"v" => 0.5}} = v2_point("zz v=.5")
      assert %{fields: %{"v" => -0.5}} = v2_point("zz v=-.5")
      assert %{fields: %{"v" => 10.0}} = v2_point("zz v=1.e1")
      assert %{fields: %{"v" => 50.0}} = v2_point("zz v=5.e1")
      assert %{fields: %{"s" => "x"}} = v2_point(~S|zz s="x"|)
      # InfluxDB 2 drops the last byte of the value, whatever it is.
      assert %{fields: %{"s" => ~S|x"|}} = v2_point("zz s=\"x\"\r")
      assert %{fields: %{"s" => ~S|a"b|}} = v2_point(~S|zz s="a\"b"|)
      assert %{fields: %{"a b" => 1.0}} = v2_point(~S|zz a\ b=1|)
      assert %{fields: %{~s|"k"| => 1.0}} = v2_point(~s|zz "k"=1|)
      assert %{fields: %{"v" => true, "w" => false}} = v2_point("zz v=T,w=false")
    end

    test "time as a field is dropped, as a tag refused" do
      assert %{fields: %{"v" => 2.0}} = v2_point("zz time=1,v=2")
      assert %{fields: fields} = v2_point("zz time=1")
      assert fields == %{}

      assert v2_error("zz,time=x v=1") ==
               {"zz,time=x v=1", ~s|cannot use reserved tag key "time"|}
    end

    test "the line is quoted without its leading whitespace" do
      assert v2_error(" \t zz v=") == {"zz v=", "missing field value"}
      assert %{measurement: "zz"} = v2_point("\t zz v=1")

      assert {:error, %{body: "incoming write was empty"}} =
               LineProtocolParser.parse_lines("\0 \t\n  # c", :nanosecond, :v2)
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxQL
  # ---------------------------------------------------------------------------

  describe "InfluxQL — keywords inside literals" do
    test "a quoted string, identifier or regex is not a keyword" do
      for statement <- [
            "SELECT v FROM o WHERE k = 'into'",
            "SELECT v FROM o WHERE k = 'fill('",
            "SELECT v FROM o WHERE k = 'group by time(1m)'",
            "SELECT v FROM o WHERE k = 'slimit 1'",
            "SELECT v FROM o WHERE k = 'tz(x)'",
            "SELECT v FROM o WHERE k =~ /fill\\(/",
            "SELECT v FROM o WHERE k !~ /into/",
            ~s|SELECT "into" FROM o|,
            ~s|SELECT v FROM o WHERE k = 'it\\'s into'|
          ] do
        assert {:ok, %{measurement: "o"}} = InfluxQL.parse(statement), statement
      end
    end

    test "a keyword inside a literal does not end a clause" do
      assert {:ok, %{where: "k = 'group by x limit 5'", limit: nil, group_by: []}} =
               InfluxQL.parse("SELECT v FROM o WHERE k = 'group by x limit 5'")

      assert {:ok, %{where: "k = 'a'", group_by: ["k"], limit: 2, offset: 1}} =
               InfluxQL.parse("SELECT v FROM o WHERE k = 'a' GROUP BY k LIMIT 2 OFFSET 1")

      assert {:ok, %{measurement: "my m"}} = InfluxQL.parse(~s|SELECT v FROM "my m"|)
    end

    test "a keyword outside a literal is still refused by name" do
      for {statement, name} <- [
            {"SELECT v INTO x FROM o", "INTO"},
            {"SELECT v FROM o fill(none)", "fill()"},
            {"SELECT v FROM o SLIMIT 1", "SLIMIT/SOFFSET"},
            {"SELECT v FROM (SELECT v FROM o)", "subqueries"},
            {"SELECT mean(v) FROM o GROUP BY time(1m)", "GROUP BY time(...)"},
            {"SELECT v FROM o GROUP BY *", "GROUP BY *"},
            {"SELECT v FROM o WHERE k = 'a' tz('UTC')", "tz()"}
          ] do
        assert InfluxQL.parse(statement) == {:error, "unsupported InfluxQL (#{name})"}, statement
      end
    end

    test "a long literal is no problem for the clause patterns" do
      long = String.duplicate("x", 5_000)
      assert {:ok, %{where: where}} = InfluxQL.parse("SELECT v FROM o WHERE k = '#{long}'")
      assert where == "k = '#{long}'"
    end
  end

  describe "InfluxQL — WHERE and time" do
    @tags MapSet.new(["k"])

    defp plan(where) do
      assert {:ok, plan} = InfluxQL.where_plan(where, @tags)
      plan
    end

    test "next to time an integer or a duration is nanoseconds since the epoch" do
      assert %{sql: "time >= '1970-01-01T00:00:00.000000002Z'", lowers: [2]} = plan("time >= 2")
      assert %{sql: "time > '1970-01-01T00:00:00.000000000Z'", lowers: [1]} = plan("time > 0s")
      assert %{sql: "time > '1970-01-01T00:00:00.000000002Z'", lowers: [3]} = plan("time > 2ns")
      assert %{sql: "time = '1970-01-01T00:00:00.000002000Z'", lowers: [2000]} = plan("time = 2u")
      assert %{sql: "time < '1970-01-01T00:00:01.000000000Z'", lowers: []} = plan("time < 1s")
      assert %{sql: "time > '1969-12-31T23:59:59.999999999Z'", lowers: [0]} = plan("time > -1")
    end

    test "the comparand may be on either side, and a constant adds and subtracts" do
      assert %{sql: "time <= '1970-01-01T00:00:00.000000002Z'", lowers: []} = plan("2 >= time")
      assert %{sql: "time >= '1970-01-01T00:00:00.000000002Z'", lowers: [2]} = plan("2 <= time")

      assert %{sql: "time > '1970-01-01T00:00:00.000000002Z'", lowers: [3]} =
               plan("time > 1 + 1")

      assert %{sql: "time > '1970-01-01T00:00:00.000000001Z'", lowers: [2]} =
               plan("time > 1s - 999999999ns")

      assert %{sql: "time > '1969-12-31T23:59:59.999999998Z'"} = plan("time > -1 - 1")
    end

    test "a quoted time is passed on, and now() is an interval" do
      assert %{sql: "time >= '2026-03-31T12:00:00Z'", lowers: [1_774_958_400_000_000_000]} =
               plan("time >= '2026-03-31T12:00:00Z'")

      assert %{
               sql: "time > now() - INTERVAL '1800 seconds'",
               lowers: [{:now, -1_799_999_999_999}]
             } = plan("time > now() - 30m")

      assert %{sql: "time >= now() + INTERVAL '60 seconds' - INTERVAL '1 seconds'"} =
               plan("time >= now() + 1m - 1s")
    end

    test "the lower bounds of a conjunction, and tags beside time" do
      assert %{
               sql: "k = 'a' AND time >= '1970-01-01T00:00:00.000000002Z'",
               lowers: [2]
             } = plan("k = 'a' AND time >= 2")

      assert %{lowers: [2, 3]} = plan("time >= 2 AND time > 2")
      assert %{lowers: [2]} = plan("(time >= 2)")
      assert %{lowers: [2]} = plan("(k = 'a' OR k = 'b') AND time >= 2")

      assert %{sql: "(k = 'a' OR k = 'b') AND" <> _rest} =
               plan("(k = 'a' OR k = 'b') AND time >= 2")

      assert %{lowers: []} = plan("k = 'a' OR k = 'b'")
    end

    test "the engine's planning error for != and <>, whatever the comparand" do
      body =
        "rewriting statement\ncaused by\nsplit condition\ncaused by\n" <>
          "Error during planning: invalid time comparison operator: !="

      for where <- ["time != 2", "time <> 2", "time <> 2s", "2 != time", "time != '2026-01-01'"] do
        assert InfluxQL.where_plan(where, @tags) == {:error, {:engine, body}}, where
      end
    end

    test "what the double refuses by name" do
      for {where, message} <- [
            {"time > 0.5", "unsupported InfluxQL (non-integer time 0.5)"},
            {"time > now() - 500ms", "unsupported InfluxQL (sub-second duration 500ms)"},
            {"time >= 2 OR k = 'a'", "unsupported InfluxQL (a time comparison inside OR)"},
            {"k = 'a' OR (k = 'b' AND time >= 2)",
             "unsupported InfluxQL (a time comparison inside OR)"},
            {"time > now() - 1 ",
             "unsupported InfluxQL (a time compared with now() and something else)"},
            {"time > 1 * 2", "unsupported InfluxQL (a time compared with an expression)"}
          ] do
        assert {:error, ^message} = InfluxQL.where_plan(where, @tags)
      end
    end

    test "tags are strings and regexes are unanchored, as before" do
      assert %{sql: "k ~ 'a.c'", lowers: []} = plan("k =~ /a.c/")
      assert %{sql: "(k IS NULL AND k IS NOT NULL)"} = plan("k > 'a'")
      assert %{sql: "f > 1"} = plan("f > 1")
      assert %{idents: idents} = plan("k = 'a' AND f > 1 AND time >= 2")
      assert MapSet.equal?(idents, MapSet.new(["k", "f", "time"]))
    end
  end

  describe "InfluxQL — run/4" do
    defp row(us, fields),
      do: Map.merge(%{"time" => DateTime.from_unix!(us, :microsecond)}, fields)

    defp run(statement, rows, opts \\ []) do
      assert {:ok, query} = InfluxQL.parse(statement)
      InfluxQL.run(query, rows, MapSet.new(["k"]), opts)
    end

    defp rows do
      [
        row(1, %{"k" => "a", "v" => 1.0, "w" => 10.0}),
        row(2, %{"k" => "b", "v" => 2.0, "w" => 20.0}),
        row(3, %{"k" => "a", "v" => 3.0, "w" => 30.0}),
        row(5, %{"k" => "c", "x" => 7})
      ]
    end

    test "an aggregate is stamped with the lower bound, the epoch without one" do
      epoch = DateTime.from_unix!(0, :microsecond)
      assert [%{"mean" => 2.0, "time" => ^epoch}] = run("SELECT mean(v) FROM o", rows())

      two = DateTime.from_unix!(2, :microsecond)
      assert [%{"time" => ^two}] = run("SELECT mean(v) FROM o", rows(), lower: 2_000)
      # A bound below a microsecond is cut to it, as every time is.
      assert [%{"time" => ^epoch}] = run("SELECT mean(v) FROM o", rows(), lower: 2)
      assert [%{"time" => ^two}] = run("SELECT mean(v) FROM o", rows(), lower: 2_001)

      before_epoch = DateTime.from_unix!(-1, :microsecond)
      assert [%{"time" => ^before_epoch}] = run("SELECT mean(v) FROM o", rows(), lower: -1_000)
    end

    test "with GROUP BY every series carries the bound; a lone selector keeps its point" do
      two = DateTime.from_unix!(2, :microsecond)

      assert [%{"k" => "a", "time" => ^two}, %{"k" => "b", "time" => ^two}] =
               run("SELECT mean(v) FROM o GROUP BY k", rows(), lower: 2_000)

      three = DateTime.from_unix!(3, :microsecond)

      assert [%{"max" => 3.0, "time" => ^three}] =
               run("SELECT max(v) FROM o", rows(), lower: 2_000)
    end

    test "LIMIT and OFFSET count per selected field" do
      assert [%{"v" => 1.0}, %{"v" => 2.0}, %{"x" => 7}] =
               run("SELECT v, x FROM o LIMIT 2", rows())
               |> Enum.map(&Map.drop(&1, ["time", "iox::measurement"]))

      assert [%{"v" => 1.0, "w" => 10.0, "k" => "a"}, %{"x" => 7, "k" => "c"}] =
               run("SELECT * FROM o LIMIT 1", rows(), fields: ["v", "w", "x"])
               |> Enum.map(&Map.drop(&1, ["time", "iox::measurement"]))

      assert [%{"v" => 2.0}] =
               run("SELECT v FROM o LIMIT 1 OFFSET 1", rows())
               |> Enum.map(&Map.drop(&1, ["time", "iox::measurement"]))

      assert [] = run("SELECT * FROM o LIMIT 0", rows())

      # v and w have a third row, x has none.
      assert [%{"k" => "a", "v" => 3.0, "w" => 30.0}] =
               run("SELECT * FROM o OFFSET 2", rows())
               |> Enum.map(&Map.drop(&1, ["time", "iox::measurement"]))
    end

    test "an alias is the name a window counts" do
      assert [%{"vee" => 1.0}, %{"vee" => 2.0}] =
               run("SELECT v AS vee FROM o LIMIT 2", rows())
               |> Enum.map(&Map.drop(&1, ["time", "iox::measurement"]))
    end

    test "rows are shaped in the order they come, not sorted again" do
      unordered = [row(3, %{"v" => 3.0}), row(1, %{"v" => 1.0})]
      assert [%{"v" => 3.0}, %{"v" => 1.0}] = run("SELECT v FROM o", unordered)
      assert [] = run("SELECT v FROM o", [])
    end
  end

  # ---------------------------------------------------------------------------
  # Flux
  # ---------------------------------------------------------------------------

  describe "Flux — range" do
    @now 1_700_000_000_000_000_000

    defp flux_range(args) do
      Flux.parse(~s|from(bucket: "b") \|> range(#{args})|, @now)
    end

    defp bounds(args) do
      assert {:ok, %{stages: [{:range, start, stop}]}} = flux_range(args)
      {start, stop}
    end

    test "integer seconds wrap in 64-bit nanoseconds" do
      assert {0, stop} = bounds("start: 0, stop: 99999999999999")
      assert DateTime.from_unix!(stop, :nanosecond) == ~U[1976-05-08 04:06:59.520689Z]

      assert {0, 9_223_372_036_000_000_000} = bounds("start: 0, stop: 9223372036")
      assert {0, -709_551_616} = bounds("start: 0, stop: 18446744073")
      assert {-709_551_616, 1_290_448_384} = bounds("start: 18446744073, stop: 18446744075")
    end

    test "a duration is taken from now and wraps too" do
      assert {start, @now} = bounds("start: -1h, stop: now()")
      assert start == @now - 3_600_000_000_000
      assert {@now, stop} = bounds("start: now(), stop: 1w")
      assert stop == @now + 604_800_000_000_000

      assert {wrapped, _stop} = bounds("start: -99999999999w, stop: now()")
      assert wrapped in -9_223_372_036_854_775_808..9_223_372_036_854_775_807
      assert DateTime.from_unix!(wrapped, :nanosecond).year in 1678..2261
    end

    test "an RFC3339 time that does not fit wraps" do
      assert {start, _stop} = bounds("start: 0001-01-01T00:00:00Z, stop: now()")
      assert DateTime.from_unix!(start, :nanosecond) == ~U[1754-08-30 22:43:41.128654Z]
    end

    test "a range with no time in it is the engine's plan error" do
      message = "error in building plan while starting program: cannot query an empty range"

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
        assert flux_range(args) == {:error, message}, args
      end

      # Judged on the seconds as Go counts them, these have a range.
      for args <- [
            "start: 0, stop: 18446744073",
            "start: 9223372037, stop: 9223372038",
            "start: 18446744073, stop: 18446744075"
          ] do
        assert {:ok, _query} = flux_range(args), args
      end
    end

    test "the measurements a query reads" do
      reads = fn filters ->
        assert {:ok, query} =
                 Flux.parse(~s|from(bucket: "b") \|> range(start: 0) #{filters}|, @now)

        Flux.measurements(query)
      end

      assert reads.("") == :all
      assert reads.(~s/|> filter(fn: (r) => r._field == "v")/) == :all
      assert reads.(~s/|> filter(fn: (r) => r._measurement == "a")/) == ["a"]

      assert reads.(~s/|> filter(fn: (r) => r._measurement == "a" or r._measurement == "b")/) ==
               ["a", "b"]

      assert reads.(~s/|> filter(fn: (r) => r._measurement == "a" and r.host == "x")/) == ["a"]
      assert reads.(~s/|> filter(fn: (r) => r._measurement == "a" or r.host == "x")/) == :all
      assert reads.(~s/|> filter(fn: (r) => not (r._measurement == "a"))/) == :all
      assert reads.(~s/|> filter(fn: (r) => r._measurement != "a")/) == :all

      assert reads.(
               ~s/|> filter(fn: (r) => r._measurement == "a" or r._measurement == "b")/ <>
                 ~s/ |> filter(fn: (r) => r._measurement == "b")/
             ) == ["b"]

      assert reads.(
               ~s/|> filter(fn: (r) => r._measurement == "a")/ <>
                 ~s/ |> filter(fn: (r) => r._measurement == "b")/
             ) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Through the double
  # ---------------------------------------------------------------------------

  defp v3_conn(databases \\ ["db"]) do
    {:ok, conn} = Local.start(databases: databases, profile: :v3_core)
    on_exit(fn -> Local.stop(conn) end)
    conn
  end

  defp v2_conn(buckets \\ ["b"]) do
    {:ok, conn} = Local.start(profile: :v2)
    Enum.each(buckets, &Local.create_bucket(conn, &1))
    on_exit(fn -> Local.stop(conn) end)
    conn
  end

  defp error_body(result) do
    assert {:error, %{body: body}} = result
    Jason.decode!(body)
  end

  describe "write/3 — InfluxDB 2" do
    test "every line that fails is reported, joined by newlines, and nothing is stored" do
      conn = v2_conn()

      assert %{"code" => "invalid", "message" => message} =
               error_body(Local.write(conn, "m v=1 5\nbad line\nm v=\n  m w=2 5", database: "b"))

      assert message ==
               "unable to parse 'bad line': invalid field format\n" <>
                 "unable to parse 'm v=': missing field value"

      assert {:ok, []} = Local.query_flux(conn, ~s|from(bucket: "b") \|> range(start: 0)|)
    end

    test "a point whose only field is time is dropped with the engine's 422" do
      conn = v2_conn()
      assert {:ok, :written} = Local.write(conn, "m time=1,v=2 5", database: "b")

      assert error_body(Local.write(conn, "m time=1 5", database: "b")) == %{
               "code" => "unprocessable entity",
               "message" =>
                 "failure writing points to database: partial write: invalid field name: " <>
                   ~s|input field "time" on measurement "m" is invalid dropped=1|
             }

      assert {:ok, rows} = Local.query_flux(conn, ~s|from(bucket: "b") \|> range(start: 0)|)
      assert Enum.map(rows, & &1["_field"]) == ["v"]
    end

    test "dropped points are counted per shard group, and the last group's first drop speaks" do
      conn = v2_conn()
      assert {:ok, :written} = Local.write(conn, "m v=1.5 5", database: "b")

      conflict = fn field, measurement, got, dropped ->
        "failure writing points to database: partial write: field type conflict: " <>
          ~s|input field "#{field}" on measurement "#{measurement}" is type #{got}, | <>
          "already exists as type float dropped=#{dropped}"
      end

      invalid = fn measurement, dropped ->
        "failure writing points to database: partial write: invalid field name: " <>
          ~s|input field "time" on measurement "#{measurement}" is invalid dropped=#{dropped}|
      end

      for {payload, expected} <- [
            # one group: the first drop speaks, all are counted
            {"m time=1 5\nm v=1i 6", invalid.("m", 2)},
            {"m v=1i 6\nm time=1 5", conflict.("v", "m", "integer", 2)},
            {"m v=1i 6\nm v=2i 6\nm time=1 5\nm time=1 6", conflict.("v", "m", "integer", 4)},
            # a week apart: two groups, the last one speaks
            {"m time=1\nm v=1i 5", conflict.("v", "m", "integer", 1)},
            {"m v=1i 5\nm time=1", invalid.("m", 1)},
            {"m time=1\nm time=2 5\nn time=3", invalid.("m", 1)},
            {"n time=3\nm time=3", invalid.("n", 2)},
            {"m v=1i 1000000000000000\nm v=2i 1\nm time=1 2", conflict.("v", "m", "integer", 2)}
          ] do
        assert %{"code" => "unprocessable entity", "message" => ^expected} =
                 error_body(Local.write(conn, payload, database: "b")),
               payload
      end
    end

    test "the shard group of a bucket follows its retention" do
      conn = v2_conn([])
      :ok = Local.create_bucket(conn, "hourly", retention: 3600)
      :ok = Local.create_bucket(conn, "daily", retention: 259_200)
      assert {:ok, :written} = Local.write(conn, "m v=1.5 5", database: "hourly")
      assert {:ok, :written} = Local.write(conn, "m v=1.5 5", database: "daily")

      # 2 hours apart: two groups in an hourly bucket, one in a daily one.
      payload = "m v=1i 5\nm time=1 7200000000000"
      assert %{"message" => hourly} = error_body(Local.write(conn, payload, database: "hourly"))
      assert hourly =~ "invalid field name"
      assert hourly =~ "dropped=1"
      assert %{"message" => daily} = error_body(Local.write(conn, payload, database: "daily"))
      assert daily =~ "field type conflict"
      assert daily =~ "dropped=2"
    end
  end

  describe "list_buckets/1" do
    test "a bucket carries the engine's fields and a stable orgID" do
      {:ok, conn} = Local.start(profile: :v2, org: "acme")
      on_exit(fn -> Local.stop(conn) end)
      :ok = Local.create_bucket(conn, "one")
      :ok = Local.create_bucket(conn, "two", retention: 86_400)

      assert {:ok, [one, two]} = Local.list_buckets(conn)
      assert {:ok, [^one, ^two]} = Local.list_buckets(conn)

      assert Map.keys(one) |> Enum.sort() ==
               ~w(createdAt id labels links name orgID retentionRules type updatedAt)

      assert %{"type" => "user", "name" => "one", "labels" => [], "orgID" => org_id} = one
      assert org_id =~ ~r/\A[0-9a-f]{16}\z/
      assert two["orgID"] == org_id
      assert one["id"] =~ ~r/\A[0-9a-f]{16}\z/
      assert one["id"] != two["id"]
      assert one["createdAt"] =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{9}Z\z/

      assert one["retentionRules"] == [
               %{"type" => "expire", "everySeconds" => 0, "shardGroupDurationSeconds" => 604_800}
             ]

      assert two["retentionRules"] == [
               %{
                 "type" => "expire",
                 "everySeconds" => 86_400,
                 "shardGroupDurationSeconds" => 3_600
               }
             ]

      assert one["links"] == %{
               "labels" => "/api/v2/buckets/#{one["id"]}/labels",
               "members" => "/api/v2/buckets/#{one["id"]}/members",
               "org" => "/api/v2/orgs/#{org_id}",
               "owners" => "/api/v2/buckets/#{one["id"]}/owners",
               "self" => "/api/v2/buckets/#{one["id"]}",
               "write" => "/api/v2/write?org=#{org_id}&bucket=#{one["id"]}"
             }

      # Another connection to the same org lists the same ids; another org does not.
      {:ok, same} = Local.start(profile: :v2, org: "acme")
      {:ok, other} = Local.start(profile: :v2, org: "other")
      on_exit(fn -> Local.stop(same) && Local.stop(other) end)
      :ok = Local.create_bucket(same, "one")
      :ok = Local.create_bucket(other, "one")
      assert {:ok, [%{"orgID" => ^org_id, "id" => id}]} = Local.list_buckets(same)
      assert id == one["id"]
      assert {:ok, [%{"orgID" => other_org}]} = Local.list_buckets(other)
      assert other_org != org_id
    end

    test "creating a bucket again keeps its creation time" do
      conn = v2_conn([])
      :ok = Local.create_bucket(conn, "one")
      {:ok, [first]} = Local.list_buckets(conn)
      Process.sleep(2)
      :ok = Local.create_bucket(conn, "one")
      assert {:ok, [^first]} = Local.list_buckets(conn)
    end
  end

  describe "query_influxql/3" do
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

    defp iq(conn, statement), do: Local.query_influxql(conn, statement, database: "db")

    defp iq_values(conn, statement, column \\ "v") do
      assert {:ok, rows} = iq(conn, statement)
      Enum.map(rows, & &1[column])
    end

    test "a keyword inside a literal is answered", %{conn: conn} do
      assert iq_values(conn, "SELECT v FROM o WHERE k = 'into'") == [4.0]
      assert iq_values(conn, "SELECT v FROM o WHERE k = 'fill('") == []
      assert iq_values(conn, "SELECT v FROM o WHERE k =~ /into/") == [4.0]
    end

    test "time against integers and durations, to the nanosecond", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "n v=1 1\nn v=2 2\nn v=3 3\nn v=4 4", database: "db")

      for {where, expected} <- [
            {"time > 0s", [1.0, 2.0, 3.0, 4.0]},
            {"time >= 2", [2.0, 3.0, 4.0]},
            {"time > 2ns", [3.0, 4.0]},
            {"2 <= time", [2.0, 3.0, 4.0]},
            {"time = 2", [2.0]},
            {"time >= 2 AND time < 4", [2.0, 3.0]},
            {"time > 1u", []},
            {"time > 1s - 999999999ns", [2.0, 3.0, 4.0]}
          ] do
        assert iq_values(conn, "SELECT v FROM n WHERE #{where}") == expected, where
      end
    end

    test "time != is the engine's planning error", %{conn: conn} do
      assert {:error, %{status: 400, body: body}} = iq(conn, "SELECT v FROM o WHERE time != 2")
      assert body =~ "invalid time comparison operator: !="
    end

    test "an aggregate time is the lower bound at the nanosecond, then cut to a microsecond",
         %{conn: conn} do
      {:ok, :written} = Local.write(conn, "n v=1 1\nn v=2 2\nn v=3 3\nn v=4 4", database: "db")
      epoch = DateTime.from_unix!(0, :microsecond)

      assert {:ok, [%{"mean" => 3.0, "time" => ^epoch}]} =
               iq(conn, "SELECT mean(v) FROM n WHERE time >= 2")

      two_us = DateTime.from_unix!(2, :microsecond)

      assert {:ok, [%{"mean" => 3.0, "time" => ^two_us}]} =
               iq(conn, "SELECT mean(v) FROM o WHERE time >= 2000")

      assert {:ok, [%{"mean" => 1.5, "time" => ^epoch}]} =
               iq(conn, "SELECT mean(v) FROM o WHERE time < 3000")

      assert {:ok, [%{"mean" => 4.0, "time" => ^two_us}]} =
               iq(conn, "SELECT mean(v) FROM o WHERE time > 1500 AND time >= 2000 AND k = 'into'")
    end

    test "a bound taken from now() is stamped on the aggregate", %{conn: conn} do
      before = System.os_time(:microsecond) - 3_600_000_000

      assert {:ok, []} = iq(conn, "SELECT mean(v) FROM o WHERE time > now() - 1h")

      now = Local.write(conn, "fresh v=1 #{System.os_time(:nanosecond)}", database: "db")
      assert {:ok, :written} = now

      assert {:ok, [%{"time" => time}]} =
               iq(conn, "SELECT mean(v) FROM fresh WHERE time > now() - 1h")

      assert abs(DateTime.to_unix(time, :microsecond) - before) < 60_000_000
    end

    test "LIMIT counts per field", %{conn: conn} do
      assert {:ok, rows} = iq(conn, "SELECT v, x FROM o LIMIT 2")
      assert Enum.map(rows, &{&1["v"], &1["x"]}) == [{1.0, nil}, {2.0, nil}, {nil, 7}]

      assert {:ok, rows} = iq(conn, "SELECT * FROM o LIMIT 1")
      assert Enum.map(rows, &{&1["k"], &1["v"], &1["x"]}) == [{"a", 1.0, nil}, {"c", nil, 7}]
      assert {:ok, [%{"v" => 2.0}]} = iq(conn, "SELECT v FROM o LIMIT 1 OFFSET 1")
    end

    test "a query with a WHERE on a tag finds the points that lack it", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "o v=9,w=90 6000", database: "db")
      assert iq_values(conn, "SELECT v FROM o WHERE k = ''") == [9.0]
      assert iq_values(conn, "SELECT v FROM o WHERE k != 'a'") == [2.0, 4.0, 9.0]
      assert {:ok, rows} = iq(conn, "SELECT * FROM o WHERE k = ''")
      refute Enum.any?(rows, &Map.has_key?(&1, "k"))
      assert {:ok, rows} = iq(conn, "SELECT * FROM o")
      assert length(rows) == 6
      refute Enum.any?(rows, &(&1["k"] == ""))
    end

    test "SHOW MEASUREMENTS lists the measurements by name", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "zz v=1 1\naa v=1 1\nmm v=1 1", database: "db")
      assert {:ok, rows} = iq(conn, "SHOW MEASUREMENTS")
      assert Enum.map(rows, & &1["name"]) == ["aa", "mm", "o", "zz"]
    end
  end

  describe "query_flux/3" do
    test "a filter on _measurement reads only those, and the tables are numbered the same" do
      conn = v2_conn()

      lp = """
      a,h=x v=1 1000000000
      b,h=x v=2 1000000000
      c,h=x v=3 1000000000
      a,h=y v=4 2000000000
      """

      assert {:ok, :written} = Local.write(conn, String.trim(lp), database: "b")
      base = ~s|from(bucket: "b") \|> range(start: 0, stop: 100) |

      all = fn extra -> Local.query_flux(conn, base <> extra) end

      assert {:ok, rows} =
               all.(~s/|> filter(fn: (r) => r._measurement == "a" or r._measurement == "c")/)

      assert Enum.map(rows, &{&1["table"], &1["_measurement"], &1["h"], &1["_value"]}) == [
               {0, "a", "x", 1.0},
               {1, "a", "y", 4.0},
               {2, "c", "x", 3.0}
             ]

      assert {:ok, [%{"table" => 0, "_value" => 2.0}]} =
               all.(~s/|> filter(fn: (r) => r._measurement == "b")/)

      assert {:ok, []} = all.(~s/|> filter(fn: (r) => r._measurement == "nope")/)

      assert {:ok, [%{"table" => 0, "_value" => 4.0}]} =
               all.(~s/|> filter(fn: (r) => r._measurement == "a" and r.h == "y")/)

      assert {:ok, rows} =
               all.(~s/|> filter(fn: (r) => r._measurement != "b") |> last()/)

      assert Enum.map(rows, & &1["_value"]) == [1.0, 4.0, 3.0]
    end

    test "integer seconds that do not fit wrap instead of raising" do
      conn = v2_conn()
      assert {:ok, :written} = Local.write(conn, "m v=1 5\nm v=2 1000000000", database: "b")

      query = fn stop ->
        Local.query_flux(
          conn,
          ~s|from(bucket: "b") \|> range(start: 0, stop: #{stop})|
        )
      end

      assert {:ok, rows} = query.("99999999999999")
      assert Enum.map(rows, & &1["_value"]) == [1.0, 2.0]
      assert Enum.all?(rows, &(&1["_stop"] == ~U[1976-05-08 04:06:59.520689Z]))
      assert {:ok, []} = query.("18446744073")

      assert %{"code" => "invalid", "message" => "error in building plan" <> _rest} =
               error_body(query.("0"))
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

      assert Store.measurements(table, "db") == ["aa", "mm", "zz"]
      assert Store.measurements(table, "other") == ["xx"]
      assert Store.measurements(table, "none") == []
    end

    test "points_in_db reads the measurements it is asked for" do
      table = Store.new(["db"])

      for m <- ["a", "b", "c"], i <- 1..3 do
        Store.store_point(table, "db", %{
          measurement: m,
          tags: %{},
          fields: %{"v" => i},
          timestamp: i
        })
      end

      assert table |> Store.points_in_db("db") |> length() == 9
      assert table |> Store.points_in_db("db", :all) |> length() == 9

      assert table |> Store.points_in_db("db", ["b", "a", "b"]) |> Enum.map(& &1.measurement) ==
               ["a", "a", "a", "b", "b", "b"]

      assert [] = Store.points_in_db(table, "db", [])
      assert [] = Store.points_in_db(table, "db", ["nope"])
      assert [] = Store.points_in_db(table, "db", [5])
    end

    test "a token is created whole; _admin and a taken name are :exists and spend no id" do
      table = Store.new([])
      build = fn id -> %{"id" => id, "name" => "t"} end

      assert {:ok, %{"id" => 1}} = Store.create_token(table, "a", build)
      assert :exists = Store.create_token(table, "a", build)
      assert :exists = Store.create_token(table, "_admin", build)
      assert {:ok, %{"id" => 2}} = Store.create_token(table, "b", build)
      assert :ok = Store.delete_token(table, "a")
      assert :error = Store.delete_token(table, "a")
      assert {:ok, %{"id" => 3}} = Store.create_token(table, "a", build)
    end

    test "concurrent creates of one name make one token and spend one id" do
      table = Store.new([])
      build = fn id -> %{"id" => id} end

      results =
        1..60
        |> Task.async_stream(fn _n -> Store.create_token(table, "same", build) end,
          max_concurrency: 60
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert [{:ok, %{"id" => 1}}] = Enum.filter(results, &match?({:ok, _token}, &1))
      assert Enum.count(results, &(&1 == :exists)) == 59
      assert {:ok, %{"id" => 2}} = Store.create_token(table, "next", build)
    end

    test "concurrent creates of different names give each its own id, in a row" do
      table = Store.new([])

      ids =
        1..80
        |> Task.async_stream(
          fn n ->
            {:ok, %{"id" => id}} = Store.create_token(table, "t#{n}", &%{"id" => &1})
            id
          end,
          max_concurrency: 80
        )
        |> Enum.map(fn {:ok, id} -> id end)

      assert Enum.sort(ids) == Enum.to_list(1..80)
    end

    test "a token deleted while being created is never brought back" do
      for round <- 1..100 do
        table = Store.new([])
        name = "t#{round}"
        build = &%{"id" => &1}

        creator = Task.async(fn -> Store.create_token(table, name, build) end)
        deleter = Task.async(fn -> Store.delete_token(table, name) end)
        created = Task.await(creator)
        deleted = Task.await(deleter)

        # Either the delete found the token (and it is gone), or it ran first.
        case {created, deleted} do
          {{:ok, _token}, :ok} -> assert :ok != Store.delete_token(table, name)
          {{:ok, _token}, :error} -> assert :ok = Store.delete_token(table, name)
        end
      end
    end

    test "concurrent first writes cannot pass the database limit" do
      table = Store.new([])
      check = fn existing -> if Enum.count(existing) >= 5, do: {:error, :limit}, else: :ok end

      results =
        1..40
        |> Task.async_stream(fn n -> Store.create_database(table, "db#{n}", check) end,
          max_concurrency: 40
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :ok)) == 5
      assert Enum.count(results, &(&1 == {:error, :limit})) == 35
      assert table |> Store.databases() |> MapSet.size() == 5
    end

    test "a database that exists is :ok at the limit, and a refused one is not created" do
      table = Store.new(["a", "b"])
      full = fn _existing -> {:error, :limit} end

      assert :ok = Store.create_database(table, "a", full)
      assert {:error, :limit} = Store.create_database(table, "c", full)
      refute Store.database?(table, "c")
    end

    test "the limit holds through the double, concurrently" do
      {:ok, conn} = Local.start(profile: :v3_core)
      on_exit(fn -> Local.stop(conn) end)

      results =
        1..30
        |> Task.async_stream(
          fn n -> Local.write(conn, "m v=1 #{n}", database: "limit#{n}") end,
          max_concurrency: 30
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == {:ok, :written})) == 5

      assert Enum.all?(results, fn
               {:ok, :written} -> true
               {:error, %{status: 422}} -> true
             end)

      assert {:ok, listed} = Local.list_databases(conn)
      assert length(listed) == 6
    end

    test "tokens through the double: ids count up from 1, concurrently" do
      {:ok, conn} = Local.start(profile: :v3_core)
      on_exit(fn -> Local.stop(conn) end)

      ids =
        1..40
        |> Task.async_stream(
          fn n ->
            assert {:ok, %{"id" => id}} = Local.create_token(conn, "tok#{n}")
            id
          end,
          max_concurrency: 40
        )
        |> Enum.map(fn {:ok, id} -> id end)

      assert Enum.sort(ids) == Enum.to_list(1..40)
      assert {:error, %{status: 409}} = Local.create_token(conn, "tok1")
      assert :ok = Local.delete_token(conn, "tok1")
      assert {:ok, %{"id" => 41}} = Local.create_token(conn, "tok1")
    end

    test "deleting points while the same series is rewritten keeps one merged point" do
      table = Store.new(["db"])
      Store.register_column(table, "db", "m", "v", "iox::column_type::field::integer")

      point = fn v ->
        %{measurement: "m", tags: %{"h" => "x"}, fields: %{"v" => v}, timestamp: 5}
      end

      for round <- 1..200 do
        Store.store_point(table, "db", point.(round))

        writers =
          for n <- 1..4 do
            Task.async(fn -> Store.store_point(table, "db", point.(round * 10 + n)) end)
          end

        deleter =
          Task.async(fn -> Store.delete_points(table, "db", "m", fn _point -> true end) end)

        Enum.each(writers, &Task.await/1)
        Task.await(deleter)

        # However the race fell, what is left is one merged point or none.
        assert length(Store.points(table, "db", "m")) <= 1
        Store.delete_points(table, "db", "m", fn _point -> true end)
      end
    end
  end
end
