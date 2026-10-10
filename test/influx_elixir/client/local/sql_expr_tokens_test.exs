defmodule InfluxElixir.Client.Local.SQLExprTokensTest do
  @moduledoc """
  The SQL text is read in windows of 16 KB. A token that one cuts (a long string, a number
  cut inside its exponent) is read whole, and an expression nested deep is read in memory
  that grows with its length: each is a query through `Client.Local.query_sql/3`, with the
  text padded so that a cut falls inside the token, whatever the query's own prefix.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  # The padding sweeps this span, which holds the end of the first 16 KB window.
  @cuts 16_330..16_420

  setup do
    {:ok, conn} = Local.start(databases: ["tok"])
    {:ok, conn: conn}
  end

  test "a long string literal is one token wherever a window cuts it", %{conn: conn} do
    text = String.duplicate("é", 8_200)
    line = "m s=\"" <> text <> "\",v=1i 1"
    {:ok, :written} = Local.write(conn, line, database: "tok")

    # `é` is two bytes: the string spans the first window's end for every padding.
    for pad <- Enum.take_every(@cuts, 7) do
      sql = "SELECT v FROM m WHERE" <> String.duplicate(" ", pad - 16_330) <> " s = '#{text}'"
      assert Local.query_sql(conn, sql, database: "tok") === {:ok, [%{"v" => 1}]}, inspect(pad)
    end
  end

  test "a number is one token wherever a window cuts its exponent", %{conn: conn} do
    {:ok, :written} = Local.write(conn, "m v=2.0 1", database: "tok")

    for pad <- @cuts,
        {number, rows} <- [{"1.5e+78", [%{"v" => 2.0}]}, {"1e5", [%{"v" => 2.0}]}, {".5e-3", []}] do
      sql = "SELECT v FROM m WHERE" <> String.duplicate(" ", pad) <> "v < " <> number
      assert Local.query_sql(conn, sql, database: "tok") === {:ok, rows}, inspect({pad, number})
    end
  end

  @limit "SQL error: RecursionLimitExceeded (current limit: 50)"

  test "an expression nested past the parser's recursion limit is its error, early and small",
       %{conn: conn} do
    {:ok, :written} = Local.write(conn, "m v=1i 1", database: "tok")
    sql = fn depth -> "SELECT v FROM m WHERE " <> nested(depth) <> " > 0" end

    # Core 3.10.1: `(v + (v + ... v))` of 24 operands answers, of 25 is a 400.
    assert Local.query_sql(conn, sql.(24), database: "tok") === {:ok, [%{"v" => 1}]}

    assert Local.query_sql(conn, sql.(25), database: "tok") ===
             {:error, %{status: 400, body: @limit}}

    assert capped(fn -> Local.query_sql(conn, sql.(20_000), database: "tok") end) ===
             {:error, %{status: 400, body: @limit}}
  end

  test "check_sql refuses a long text nested past the limit from its first bytes" do
    padded = "SELECT v FROM m WHERE " <> nested(25) <> " > 0" <> String.duplicate(" ", 9_000)

    assert Local.check_sql(padded) === {:error, %{status: 400, body: @limit}}
    assert Local.check_sql(String.replace(padded, nested(25), nested(3))) === :ok
  end

  test "a long text with more CASEs open than Core was probed to answer is refused by name",
       %{conn: conn} do
    {:ok, :written} = Local.write(conn, "m v=1i 1", database: "tok")

    sql = fn depth ->
      "SELECT " <>
        String.duplicate("CASE WHEN true THEN ", depth) <>
        "1" <>
        String.duplicate(" END", depth) <> " AS x" <> String.duplicate(" ", 9_000) <> "FROM m"
    end

    assert Local.query_sql(conn, sql.(20), database: "tok") === {:ok, [%{"x" => 1}]}

    assert {:error,
            %{
              status: 400,
              body:
                "Client.Local: unsupported SQL (statement nested deeper than Core was" <> _rest
            }} = Local.query_sql(conn, sql.(21), database: "tok")
  end

  # `depth` operands of `v`, nested as `(v + (v + ... v))`.
  defp nested(depth),
    do: String.duplicate("(v + ", depth - 1) <> "v" <> String.duplicate(")", depth - 1)

  # The answer of `fun` in a process whose heap is capped at five million words (about
  # 40 MB): `{:killed, reason}` when the cap kills it.
  defp capped(fun) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: 5_000_000, kill: true, error_logger: false})
        send(parent, {ref, fun.()})
      end)

    receive do
      {^ref, answer} ->
        Process.demonitor(monitor, [:flush])
        answer

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:killed, reason}
    end
  end
end
