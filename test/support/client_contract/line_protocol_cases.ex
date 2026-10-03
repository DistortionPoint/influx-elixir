defmodule InfluxElixir.ClientContract.LineProtocolCases do
  @moduledoc """
  The case tables of `InfluxElixir.ClientContract.LineProtocol`: the lines the two
  engines refuse, in their words, the lines they store, and the payloads whose
  errors are numbered and echoed.

  Every expectation was read from InfluxDB 3 Core (3.10.1) or InfluxDB 2.7. The
  grammar of the InfluxDB 3 profiles is spelled `v3`, InfluxDB 2's `v2`.
  `InfluxElixir.ContractCaseTablesTest` checks that no case is written twice in a
  table, the measurement name of the first line left out of what identifies it.
  """

  @trailing "Could not parse entire line. Found trailing content: "
  @no_fields "No fields were provided"
  @need_space "Expected at least one space character, got end of input"

  @doc """
  A line or a payload without the name of the measurement its first line begins with,
  so that the same case written with `zz`, `m` or `~m` is the same case. Only a name
  of letters, digits and underscores is left out: a measurement with a backslash, a
  quote or a tab in it is the case.
  """
  @spec measurement_free(binary()) :: binary()
  def measurement_free(text), do: Regex.replace(~r/\A[A-Za-z0-9_~]+/, text, "MEASUREMENT")

  @doc "InfluxDB 3: `{line, message}`. The line is refused with this message."
  @spec v3_errors() :: [{binary(), binary()}]
  def v3_errors do
    [
      # Most errors quote ten characters of what is left, and dots for the rest.
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
       "Tag set malformed: could not find equals sign in `t=1,uuuuuu...`"},
      # "Expected at least one space character" quotes all of what is left.
      {"zz\tabcdefghijklmnop v=1",
       "Expected at least one space character, got `\tabcdefghijklmnop v=1`"},
      # A number is the longest match; what follows is trailing content.
      {"zz v=5.", @trailing <> "`.`"},
      {"zz v=1e", @trailing <> "`e`"},
      {"zz v=0x10", @trailing <> "`x10`"},
      {"zz v=1_000", @trailing <> "`_000`"},
      {"zz v=1.5.5", @trailing <> "`.5`"},
      {"zz v=1i2", @trailing <> "`2`"},
      {"zz v=1ii", @trailing <> "`i`"},
      {"zz v=5.i", @trailing <> "`.i`"},
      {"zz v=1.0i", @trailing <> "`i`"},
      {"zz v=1e3i", @trailing <> "`i`"},
      {"zz v=1.e3", @trailing <> "`.e3`"},
      {"zz v=-5.", @trailing <> "`.`"},
      {"zz v=5.e1", @trailing <> "`.e1`"},
      {"zz v=-7u", @trailing <> "`u`"},
      {"zz v=5.u", @trailing <> "`.u`"},
      {"zz v=1.5u", @trailing <> "`u`"},
      {"zz v=1x", @trailing <> "`x`"},
      # A boolean is the longest of true, True, TRUE, t, T and the false forms.
      {"zz v=true1", @trailing <> "`1`"},
      {"zz v=tRUE", @trailing <> "`RUE`"},
      {"zz v=TrUe", @trailing <> "`rUe`"},
      {"zz v=tru", @trailing <> "`ru`"},
      # A string value ends at its closing quote.
      {~s|zz v="a"b"|, @trailing <> ~s|`b"`|},
      # After the fields: whitespace and a timestamp, then nothing.
      {"zz v=1 abc", @trailing <> "` abc`"},
      {"zz v=1 1.5", @trailing <> "`.5`"},
      {"zz v=1 +5", @trailing <> "` +5`"},
      {"zz v=1 1e3", @trailing <> "`e3`"},
      {"zz v=1 0x1", @trailing <> "`x1`"},
      {"zz v=1  ", @trailing <> "`  `"},
      {"zz v=1 5 6 7", @trailing <> "`6 7`"},
      {"zz v=1 5 6", @trailing <> "`6`"},
      {"zz v=1 100 200", @trailing <> "`200`"},
      # What is left over is quoted with what follows it, up to ten characters.
      {"zz v=5. 2", @trailing <> "`. 2`"},
      {"zz v=1e 5", @trailing <> "`e 5`"},
      {"zz v=tRUE 5", @trailing <> "`RUE 5`"},
      {"zz v=1,w= 5", @trailing <> "`w= 5`"},
      {"zz,t v=1 5", "Tag set malformed: could not find equals sign in `t v=1 5`"},
      {"zz,t= v=1 5", "Expected tag value, got ` v=1 5`"},
      {"zz,=a v=1 5", "Expected tag key, got `=a v=1 5`"},
      {"zz v=1,v=2 5", "invalid line protocol - multiple instances of 'v' field found"},
      # Prose is a measurement with a key that has no value.
      {"this is not line protocol!!", @no_fields},
      {"zz v=1 5abc", @trailing <> "`abc`"},
      {"zz v=1 5,6", @trailing <> "`,6`"},
      {"zz v=1 -", @trailing <> "` -`"},
      {"zz v=1 99999999999999999999", "Unable to parse timestamp value `99999999999999999999`"},
      # The second field that fails leaves the line after its comma, later ones at it.
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
      {"zz v=1 ,w=2", @trailing <> "` ,w=2`"},
      {~s|zz a=1,"b c"=2|, @trailing <> ~S|`"b c"=2`|},
      # A tag set is read to its end, and quotes mean nothing in a name.
      {"zz,t v=1", "Tag set malformed: could not find equals sign in `t v=1`"},
      {"zz,t=1,u v=1", "Tag set malformed: could not find equals sign in `t=1,u v=1`"},
      {"zz,t", "Tag set malformed: could not find equals sign in `t`"},
      {"zz,t=1,u=2,w v=1", "Tag set malformed: could not find equals sign in `t=1,u=2,w ...`"},
      {"zz,t=1,u=2,, v=1", "Tag set malformed: could not find equals sign in `t=1,u=2,, ...`"},
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
      {~s|m"x y" v=1|, @no_fields},
      {~s|zz,t="a b" v=1|, @no_fields},
      # A tab ends a name as a space does, but a space alone separates the sections.
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
      {"zz v=2\",g=\t\"q \" 7", @trailing <> "`\",g=\t\"q \" ...`"},
      # A carriage return ends a value or a timestamp.
      {"zz v=1i\r", @trailing <> "`\r`"},
      {"zz v=1i 5\r", @trailing <> "`\r`"},
      # A number outside what its type holds is its own error.
      {"zz v=9223372036854775808i", "Unable to parse integer value `9223372036854775808`"},
      {"zz v=18446744073709551616u",
       "Unable to parse unsigned integer value `18446744073709551616`"},
      # A field named twice, or also a tag: the first the line meets wins.
      {"zz,t=1 a=1,a=2,t=3", "invalid line protocol - multiple instances of 'a' field found"},
      {"zz,t=1 t=3,a=1,a=2",
       "invalid column type for column 't', expected iox::column_type::tag, " <>
         "got iox::column_type::field::float"},
      # A parse error comes before either.
      {"zz v=1,v=2 abc", @trailing <> "` abc`"}
    ] ++
      for(
        value <-
          ~w(.5 -.5 +5 +1i .5i e1 NaN inf -inf Infinity --1 .e3 .5u x) ++ ["\"abc", "abc\""],
        do: {"zz v=#{value}", @no_fields}
      ) ++
      for(
        line <- ["zz =1", "zz =1i", "zz v", "zz v= 1", "zz v =1", "zz ", "zz   ", "zz 5"],
        do: {line, @no_fields}
      ) ++ [{~s|zz "a b"=1|, @no_fields}]
  end

  @doc "InfluxDB 3: `{template, rows}`. The line is stored and read back as these rows (`~m` is the measurement)."
  @spec v3_stored() :: [{binary(), [map()]}]
  def v3_stored do
    [
      # a comma in a tag key or a field key, an `=` in a tag value, a trailing comma
      {"~m,t=1,,u=2 v=1", [%{",u" => "2", "t" => "1", "v" => 1.0}]},
      {"~m,t==b v=1", [%{"t" => "=b", "v" => 1.0}]},
      {"~m v=1,w,x=2 5", [%{"w,x" => 2.0, "v" => 1.0}]},
      {~s|~m "k"=1 5|, [%{~s|"k"| => 1.0}]},
      {"~m v=1,,w=2", [%{"v" => 1.0, ",w" => 2.0}]},
      {~S|~m a\ b=1|, [%{"a b" => 1.0}]},
      # the forms of a number, and a boolean
      {"~m v=1E+3", [%{"v" => 1000.0}]},
      {"~m v=1.5E-3", [%{"v" => 0.0015}]},
      {"~m v=007", [%{"v" => 7.0}]},
      {"~m v=9223372036854775807i", [%{"v" => 9_223_372_036_854_775_807}]},
      {"~m v=1u", [%{"v" => 1}]},
      {"~m a=T,b=f,c=True,d=FALSE", [%{"a" => true, "b" => false, "c" => true, "d" => false}]},
      # a string, a tab inside one
      {~S|~m v="a\"b"|, [%{"v" => ~s|a"b|}]},
      {"~m v=\"a\tb\" 5", [%{"v" => "a\tb"}]},
      # whitespace around the timestamp
      {"~m v=1 5 ", [%{"v" => 1.0}]},
      {"~m v=1 5  ", [%{"v" => 1.0}]},
      {"~m v=1  5", [%{"v" => 1.0}]},
      # leading blanks, comments and blank lines are skipped
      {"\n  # a comment\n\t \n  ~m v=1\n", [%{"v" => 1.0}]},
      # a tab before the line and inside a string are kept, an escaped one in a tag value too
      {"\t~m,h=a\\\tb s=\"x\ty\" 1", [%{"h" => "a\\\tb", "s" => "x\ty"}]},
      # a time column is compared where the case names it: here the timestamp is
      # 1000 ns, which is a microsecond
      {"~m v=1, 1000", [%{"v" => 1.0, "time" => ~U[1970-01-01 00:00:00.000001Z]}]},
      {"~m a,b=1 1000", [%{"a,b" => 1.0, "time" => ~U[1970-01-01 00:00:00.000001Z]}]},
      {"~m,,t=1 v=1 1000",
       [%{",t" => "1", "v" => 1.0, "time" => ~U[1970-01-01 00:00:00.000001Z]}]},
      {"~m,t,u=1 v=1 1000",
       [%{"t,u" => "1", "v" => 1.0, "time" => ~U[1970-01-01 00:00:00.000001Z]}]},
      {"~m,t=a=b v=1 1000",
       [%{"t" => "a=b", "v" => 1.0, "time" => ~U[1970-01-01 00:00:00.000001Z]}]},
      {"~m v=1.5e3 1000", [%{"v" => 1500.0, "time" => ~U[1970-01-01 00:00:00.000001Z]}]},
      # a carriage return is a tag value's byte
      {"~m,t=a\rb v=1i 5", [%{"t" => "a\rb", "v" => 1}]},
      # a newline inside a string value is part of the value
      {~s|~m f="a\nb" 1\n~m g=2i 2|, [%{"f" => "a\nb"}, %{"g" => 2}]},
      # a quote means nothing in a tag key, a tag value or a field key
      {~s|~m,"k"="v" "f"=1i 1|, [%{~s|"k"| => ~s|"v"|, ~s|"f"| => 1}]}
    ]
  end

  @doc "InfluxDB 3: `{suffix, tag value, measurement}`. What `m,k=a<suffix>` and `m<suffix>` hold."
  @spec v3_escapes() :: [{binary(), binary(), binary()}]
  def v3_escapes do
    [
      {~S|\,x|, "a,x", ",x"},
      {~S|\ x|, "a x", " x"},
      {~S|\=x|, "a=x", ~S|\=x|},
      {~S|\"x|, ~S|a\"x|, ~S|\"x|},
      {~S|\\x|, ~S|a\x|, ~S|\x|},
      {~S|\\=x|, ~S|a\=x|, ~S|\=x|},
      {~S|\\\,x|, ~S|a\,x|, ~S|\,x|},
      {~S|\\\\x|, ~S|a\\x|, ~S|\\x|},
      {~S|\x|, ~S|a\x|, ~S|\x|}
    ]
  end

  @doc "InfluxDB 3: `{payload, [{line_number, message, echo}]}`. The lines of a payload that are refused."
  @spec v3_numbered() :: [{binary(), [{pos_integer(), binary() | :any, binary() | :any}]}]
  def v3_numbered do
    [
      # An error is numbered among the lines that count and echoes the physical
      # line with that number; blank lines and comments are not counted.
      {"#c\nBAD1\nBAD2\nBAD3",
       [{1, @need_space, "#c"}, {2, @need_space, "BAD1"}, {3, @need_space, "BAD2"}]},
      {"\nBAD", [{1, @need_space, ""}]},
      {"BAD1\n#c\n\nBAD2\nBAD3",
       [{1, @need_space, "BAD1"}, {2, @need_space, "#c"}, {3, @need_space, ""}]},
      # The echo is cut to 20 characters and loses a carriage return.
      {"zz v=1i\r\nBAD", [{1, @trailing <> "`\r`", "zz v=1i"}, {2, @need_space, "BAD"}]},
      {"zz v=1i\r", [{1, @trailing <> "`\r`", "zz v=1i\r"}]},
      {"abcdefghijklmnopqrstuvwxyz", [{1, @need_space, "abcdefghijklmnopqrst"}]},
      {"w v=9223372036854775808i",
       [{1, "Unable to parse integer value `9223372036854775808`", "w v=9223372036854775"}]},
      {"zz v=1i 1\r\n", [{1, @trailing <> "`\r`", "zz v=1i 1"}]},
      {"zz s=\"x\"\r\n", [{1, @trailing <> "`\r`", "zz s=\"x\""}]},
      # A carriage inside the line stays in the echo; an invalid value fails the field.
      {"zz v=1i\r 1", [{1, @trailing <> "`\r 1`", "zz v=1i\r 1"}]},
      {"zz v=abc\r\n", [{1, @no_fields, "zz v=abc"}]},
      # Only spaces and tabs make a blank line, which is not counted: BAD is line 2 and
      # echoes the physical line 2.
      {"zz v=1i 1\n\v\n", [{2, @need_space, "\v"}]},
      {"zz v=1i 1\n \nBAD", [{2, @need_space, " "}]},
      # Blank lines and comments before the error are not counted, the echo is the
      # physical line with the error's number.
      {"#c\n\nzz v=1 5 6", [{1, @trailing <> "`6`", "#c"}]},
      # A quote after a field value opens a string that takes the newline.
      {~s|zz f=1"i 1\nBAD|, [{1, @trailing <> ~s|`"i 1\nBAD`|, :any}]},
      # A quote in a measurement, a tag key or a field key means nothing.
      {~s|m"a f=1i 1\nBAD|, [{2, @need_space, :any}]},
      {~s|m,k"x=1 f=1i 1\nBAD|, [{2, @need_space, :any}]},
      {~s|m f"x=1i 1\nBAD|, [{2, @need_space, :any}]},
      # A quote in the timestamp opens a string that takes the next line.
      {~s|m f=1i 1 "\nBAD|, [{1, @trailing <> ~s|`"\nBAD`|, ~s|m f=1i 1 "|}]},
      # A quote after a comma that closes the = opens nothing.
      {~s|m f=1i,"\nBAD|, [{1, :any, :any}, {2, @need_space, :any}]},
      {~s|m f=1i, "g\nBAD|, [{1, :any, :any}, {2, @need_space, :any}]},
      {~s|m f="a,b",g,"\nBAD|, [{1, :any, :any}, {2, @need_space, :any}]},
      # A backslash takes the next byte with it, a newline too.
      {"BAD1\\\nBAD2\nBAD3", [{1, @need_space, "BAD1\\"}, {2, @need_space, "BAD2"}]},
      # The engine skips a comment through its physical line.
      {~s|# a=1 "x\nBAD|, [{1, @need_space, ~s|# a=1 "x|}]}
    ]
  end

  @doc "InfluxDB 2: `{line, reason}`. The Go parser's words, as the line is quoted."
  @spec v2_errors() :: [{binary(), binary()}]
  def v2_errors do
    [
      # the key block
      {"zz", "missing fields"},
      {"zz,t=1", "missing fields"},
      {"zz,t=a\\", "missing fields"},
      {",", "missing measurement"},
      {"zz,t=1,u v=1", "missing tag value"},
      {"zz,t= v=1", "missing tag value"},
      {"zz,t", "missing tag value"},
      {"zz,t=", "missing tag value"},
      {"zz,=1 v=1", "missing tag key"},
      {"zz, v=1", "missing tag key"},
      {"zz,,t=1 v=1", "missing tag key"},
      {"zz,", "missing tag key"},
      {"zz,t=1,t=2 v=", "duplicate tags"},
      {"zz,t=a\\,b,t=a\\,b v=1", "duplicate tags"},
      # an escape is judged by the byte before it
      {~S"zq\\ v=1i 5", "invalid field format"},
      {~S"zq,t=a\\ v=1i 5", "invalid tag format"},
      {~S"zq,t\\ v=1i 5", "invalid field format"},
      {~S"zq,t\\=1 v=1i", "missing tag value"},
      {~S"zq,t=\\ v=1i", "invalid tag format"},
      {~S"zq,t\\", "missing tag value"},
      {~S"zq\\", "missing fields"},
      # the fields block
      {"zz v=1,=2", "missing field key"},
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
      {"zz v=1e5e5", "invalid float"},
      {"zz v=1e+", "invalid float"},
      {"zz v=e1", "invalid boolean"},
      {"zz v=inf", "invalid boolean"},
      {"zz v=true1", "invalid boolean"},
      {"zz v=tr", "invalid boolean"},
      {"zz v==1", "invalid boolean"},
      {"zz v=x", "invalid boolean"},
      # the time block, and what may follow it
      {"zz v=1 1.5", "bad timestamp"},
      {"zz v=1 +5", "bad timestamp"},
      {"zz v=1 1e3", "bad timestamp"},
      {"zz v=1 5\t", "bad timestamp"},
      {"zz v=1 5\r", "bad timestamp"},
      {"zz v=1 99999999999999999999",
       ~S|strconv.ParseInt: parsing "99999999999999999999": value out of range|},
      {"zz v=1 9223372036854775807",
       "time outside range -9223372036854775806 - 9223372036854775806"},
      {"zz v=1 5 #x", "point is invalid"},
      {"zz v=1 100 200", "point is invalid"},
      # numbers outside what their type holds
      {"zz v=-9223372036854775809i",
       "unable to parse integer -9223372036854775809: " <>
         ~S|strconv.ParseInt: parsing "-9223372036854775809": value out of range|},
      {"zz v=9223372036854775808i",
       "unable to parse integer 9223372036854775808: " <>
         ~S|strconv.ParseInt: parsing "9223372036854775808": value out of range|},
      {"zz v=18446744073709551616u",
       "unable to parse unsigned 18446744073709551616: " <>
         ~S|strconv.ParseUint: parsing "18446744073709551616": value out of range|},
      # prose, and the shapes of a line that is missing a part
      {"this is not line protocol!!", "invalid field format"},
      {"zz v=", "missing field value"},
      {"zz =1", "missing field key"},
      {",t=1 v=1", "missing measurement"},
      {"zz,t v=1", "missing tag value"},
      {"zz,t=a=b v=1", "invalid tag format"},
      {"zz,t=1,t=2 v=1", "duplicate tags"},
      # values the Go parser reads as another type
      {"zz v=.e3", "invalid float"},
      {"zz v=1e999", "invalid float"},
      {"zz v=tRUE", "invalid boolean"},
      {"zz v=+5", "invalid boolean"},
      {"zz v=1ii", "invalid number"},
      {"zz v=1 abc", "bad timestamp"},
      {"zz v=1 -", ~S|strconv.ParseInt: parsing "-": invalid syntax|},
      {"zz v=1 5 6", "point is invalid"},
      # a name that ends in a backslash is judged where the line scans on
      {~S"zq,t=a\\", "missing fields"},
      {~S"zq,t=a\\ ", "missing fields"},
      {~S"zq v\\", "invalid field format"},
      {~S"zq v=1i,w\\ x=1i", "invalid field format"},
      {~S"zq v=1i,w\\=1i", ~S"invalid value: field-key=w\\=1i"},
      {~S"zq v\\=1i 5", ~S"invalid value: field-key=v\\=1i"}
    ]
  end

  @doc "InfluxDB 2: `{payload, [{quoted, reason}]}`. Every line that fails, in order."
  @spec v2_payloads() :: [{binary(), [{binary(), binary()}]}]
  def v2_payloads do
    [
      # a quote in a measurement, a tag key or a field key means nothing
      {~s|m"a f=1i 1\nBAD|, [{"BAD", "missing fields"}]},
      {~s|m,k"x=1 f=1i 1\nBAD|, [{"BAD", "missing fields"}]},
      {~s|m f"x=1i 1\nBAD|, [{"BAD", "missing fields"}]},
      # a quote after a field value is part of the number's line
      {~s|m f=1"i 1\nBAD|, [{~s|m f=1"i 1\nBAD|, "invalid number"}]},
      # a backslash takes the newline with it
      {"BAD1\\\nBAD2\nBAD3", [{"BAD1\\\nBAD2", "missing fields"}, {"BAD3", "missing fields"}]},
      # the line is quoted without its leading whitespace
      {" \t zz v=", [{"zz v=", "missing field value"}]},
      # a carriage return ends a number, and stays in the quoted line
      {"zz n=1i\r\n", [{"zz n=1i\r", "invalid number"}]},
      # every line that fails is reported, joined by newlines, whatever its neighbours
      {"zz v=1 5\nbad line\nzz v=\n  zz w=2 5",
       [{"bad line", "invalid field format"}, {"zz v=", "missing field value"}]},
      # a line left open by a quote is quoted without the payload's final newline
      {~s|zz f="a\nBAD\n|, [{~s|zz f="a\nBAD|, "unbalanced quotes"}]}
    ]
  end

  @doc "InfluxDB 2: `{template, fields}`. The line is stored as these `{field, value}` pairs."
  @spec v2_stored() :: [{binary(), [{binary(), term()}]}]
  def v2_stored do
    [
      {"~m v=5.", [{"v", 5.0}]},
      {"~m v=.5", [{"v", 0.5}]},
      {"~m v=-.5", [{"v", -0.5}]},
      {"~m v=1.e1", [{"v", 10.0}]},
      {"~m v=5.e1", [{"v", 50.0}]},
      {~S|~m v="x"|, [{"v", "x"}]},
      {~S|~m v="a\"b"|, [{"v", ~s|a"b|}]},
      {~S|~m a\ b=1|, [{"a b", 1.0}]},
      {~s|~m "k"=1|, [{~s|"k"|, 1.0}]},
      {"~m v=T,w=false", [{"v", true}, {"w", false}]},
      {"~m v=1", [{"v", 1.0}]},
      {"~m v=1 5", [{"v", 1.0}]},
      {"~m v=1  5", [{"v", 1.0}]},
      {"~m v=1 5 ", [{"v", 1.0}]},
      {"~m v=1 5   ", [{"v", 1.0}]},
      {"\t ~m v=1", [{"v", 1.0}]},
      {"\n  # a comment\n   \n\t~m v=1 5\n", [{"v", 1.0}]},
      # a comment is skipped through the whole line a quote leaves open
      {~s|# a=1 "x\n~m v=1 5|, []}
    ]
  end

  @doc "InfluxDB 2: `{suffix, tag value}`. What the tag value of `m,k=a<suffix>` holds."
  @spec v2_escapes() :: [{binary(), binary()}]
  def v2_escapes do
    [
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
    ]
  end
end
