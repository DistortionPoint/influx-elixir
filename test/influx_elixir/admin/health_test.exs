defmodule InfluxElixir.Admin.HealthTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Admin.Health
  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start()
    {:ok, conn: conn}
  end

  describe "check/1" do
    test "returns pass status from local client", %{conn: conn} do
      assert {:ok, %{"status" => "pass"}} = Health.check(conn)
    end
  end
end
