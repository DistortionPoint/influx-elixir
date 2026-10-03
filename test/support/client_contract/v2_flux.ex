defmodule InfluxElixir.ClientContract.V2Flux do
  @moduledoc """
  The `:v2_flux` part of `InfluxElixir.ClientContract`:
  Flux query errors (the `:v2` profile). The rows Flux returns are pinned by
  `InfluxElixir.Contract.Flux`.
  """

  @doc false
  @spec blocks(Macro.t(), atom()) :: [Macro.t()]
  def blocks(client, :v2), do: [v2_flux_error_tests(client)]
  def blocks(_client, _profile), do: []

  defp v2_flux_error_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — error contract" do
        test "a query with no range() is a 400 naming the unbounded read", ctx do
          assert {:error, %{status: 400, body: body}} =
                   unquote(client).query_flux(ctx.conn, ~s|from(bucket: "#{ctx.database}")|)

          assert Jason.decode!(body) === %{
                   "code" => "invalid",
                   "message" =>
                     "error in building plan while starting program: cannot submit unbounded " <>
                       ~s|read to "#{ctx.database}"; try bounding 'from' with a call to 'range'|
                 }
        end

        test "a missing bucket is a 404", ctx do
          missing = InfluxElixir.IntegrationHelper.unique_name("nope")

          assert {:error, %{status: 404, body: body}} =
                   unquote(client).query_flux(
                     ctx.conn,
                     ~s|from(bucket: "#{missing}") \|> range(start: 0)|
                   )

          assert Jason.decode!(body) === %{
                   "code" => "not found",
                   "message" =>
                     ~s|failed to initialize execute state: could not find bucket "#{missing}"|
                 }
        end

        test "the mean of a string field is a 400", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxs")

          {:ok, :written} =
            unquote(client).write(ctx.conn, ~s|#{m} s="x" 1700000000000000000|,
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).query_flux(
                     ctx.conn,
                     ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}") \|> mean()|
                   )

          assert Jason.decode!(body)["message"] ===
                   "unsupported input type for mean aggregate: string"
        end
      end
    end
  end
end
