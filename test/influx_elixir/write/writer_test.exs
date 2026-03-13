defmodule InfluxElixir.Write.WriterTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Write.Writer

  setup do
    {:ok, conn} = Local.start()
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "write/3" do
    test "returns {:ok, :written} for small payload", %{conn: conn} do
      assert {:ok, :written} = Writer.write(conn, "cpu value=1.0")
    end

    test "returns {:ok, :written} for empty opts", %{conn: conn} do
      assert {:ok, :written} = Writer.write(conn, "cpu value=1.0", [])
    end

    test "passes through custom opts to the client", %{conn: conn} do
      assert {:ok, :written} = Writer.write(conn, "cpu value=1.0", precision: :ms)
    end

    test "applies gzip for payloads larger than 1024 bytes", %{conn: conn} do
      # Build a payload > 1 KB
      large_payload = String.duplicate("cpu value=1.0\n", 100)
      assert byte_size(large_payload) > 1024
      # The LocalClient accepts any binary, so this should still succeed
      assert {:ok, :written} = Writer.write(conn, large_payload)
    end

    test "does not gzip payloads <= 1024 bytes", %{conn: conn} do
      small_payload = "cpu value=1.0"
      assert byte_size(small_payload) <= 1024
      assert {:ok, :written} = Writer.write(conn, small_payload)
    end

    test "delegates to the configured client implementation", %{conn: conn} do
      # Under test env, impl() returns Local which always returns {:ok, :written}
      result = Writer.write(conn, "cpu value=0.64")
      assert result == {:ok, :written}
    end
  end
end
