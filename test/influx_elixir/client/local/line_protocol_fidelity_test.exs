defmodule InfluxElixir.Client.Local.LineProtocolFidelityTest do
  @moduledoc """
  What `Client.Local` does with a line protocol payload that the engines do not
  do, and the one thing of its parser that its own design makes observable.

  The grammar of both engines (what each refuses and the words of the refusal,
  what it stores, quotes, escapes, tabs, carriage returns, and the number and echo
  of the line an error names) is asked through `write/3` of every client by
  `InfluxElixir.ClientContract.LineProtocol`, against the double and against a real
  Core and a real 2.7. What is left here is not an answer of an engine:

    * the refusals by name, where the engine accepts a line the double cannot
      hold (a float that is infinity, a tag key given twice), and
    * the chunking of a payload: `Client.Local` parses 10,000 lines at a time, so
      that a payload does not become one list of parsed lines. An engine has no
      such seam, and its answers do not depend on where one falls; the tests
      write enough lines for bad ones to land on either side of each boundary.

  `LineProtocolParser.parse_lines/3` is not called: every branch of it that an
  answer depends on is reached by a write.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

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

  defp refusal(line) do
    conn = v3_conn()
    assert {:error, %{status: 400, body: body}} = Local.write(conn, line, database: "db")
    assert %{"data" => [%{"error_message" => message}]} = Jason.decode!(body)
    message
  end

  describe "InfluxDB 3 — what the double refuses by name" do
    test "a float too large for 64 bits is infinity on the engine, which the double refuses" do
      message =
        "Client.Local: the float 1e999 is infinity on InfluxDB 3 Core, " <>
          "which the double cannot hold"

      assert refusal("zz v=1e999") === message
      assert refusal("zz v=-2.5e999") === String.replace(message, "1e999", "-2.5e999")
    end

    test "a tag key given twice is accepted by the engine, which then fails every query" do
      assert refusal("zz,t=1,t=1 v=1") ===
               "Client.Local: the tag key t is given twice; InfluxDB 3 Core stores such a " <>
                 "line and then answers every query of the table with a 500"

      assert refusal(~S"zz,t\ x=1,t\ x=2 v=1") ===
               "Client.Local: the tag key t x is given twice; InfluxDB 3 Core stores such a " <>
                 "line and then answers every query of the table with a 500"
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
            rem(i, 3) === 0 -> "# c#{i}"
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
end
