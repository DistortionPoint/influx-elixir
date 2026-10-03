defmodule InfluxElixir.Client.Local.LineProtocolFidelityTest do
  @moduledoc """
  The one thing of the line protocol parser of `Client.Local` that its own design
  makes observable and that no engine answers.

  The grammar of both engines (what each refuses and the words of the refusal, what
  it stores, quotes, escapes, tabs, carriage returns, and the number and echo of
  the line an error names) is asked through `write/3` of every client by
  `InfluxElixir.ClientContract.LineProtocol`, against the double and against a
  real Core and a real 2.7. So are the two lines that an engine stores and the
  double refuses by name (a float that is infinity, a tag key given twice), and the
  payloads of 10,001 to 20,001 lines whose errors fall on either side of the
  double's chunk boundaries.

  What is left here is the chunking of a payload, seen from what is stored:
  `Client.Local` parses 10,000 lines at a time, so that a payload does not become
  one list of parsed lines, and every point of every chunk has to be stored. An
  engine has no such seam to test.

  `LineProtocolParser.parse_lines/3` is not called: every branch of it that an
  answer depends on is reached by a write.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.ClientContract.LineProtocol

  test "every point of a payload is stored, whichever chunk it is in" do
    # A connection's store dies with the test process, so nothing is stopped.
    {:ok, conn} = Local.start(databases: ["db"], profile: :v3_core)
    count = 10_001

    assert {:ok, :written} =
             Local.write(conn, LineProtocol.many_lines(count, [], "m"), database: "db")

    assert {:ok, rows} = Local.query_influxql(conn, "SELECT v FROM m", database: "db")
    assert Enum.map(rows, & &1["v"]) === Enum.to_list(1..count)
  end
end
