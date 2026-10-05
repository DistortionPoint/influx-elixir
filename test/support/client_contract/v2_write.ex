defmodule InfluxElixir.ClientContract.V2Write do
  @moduledoc """
  The `:v2_write` part of `InfluxElixir.ClientContract`:
  Buckets, v2 write rules, bodies, precision and duplicate points (the `:v2` profile).
  """

  @doc false
  @spec blocks(Macro.t(), atom()) :: [Macro.t()]
  def blocks(client, :v2) do
    [
      bucket_tests(client),
      v2_write_rule_tests(client),
      v2_body_tests(client),
      v2_precision_tests(client),
      v2_duplicate_tests(client)
    ]
  end

  def blocks(_client, _profile), do: []

  defp bucket_tests(client) do
    quote location: :keep do
      describe "bucket admin — contract" do
        # A v2 bucket name may hold characters that mean something in a
        # query string. `a&b` used to be written to bucket `a`, `c+d` to
        # `c d` and `e#f` to `e` (verified against InfluxDB 2.7).
        test "a bucket name with &, +, # and = is written to and deleted by name", ctx do
          name = "contract a&b+c#d=e #{InfluxElixir.IntegrationHelper.unique_name("u")}"
          assert :ok = unquote(client).create_bucket(ctx.conn, name, [])

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "enc v=1i 1",
                     database: name,
                     precision: :second
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"_value" => 1}]} =
                   unquote(client).query_flux(
                     ctx.conn,
                     ~s|from(bucket: "#{name}") \|> range(start: 0)|
                   )

          assert :ok = unquote(client).delete_bucket(ctx.conn, name)
          {:ok, buckets} = unquote(client).list_buckets(ctx.conn)
          refute name in Enum.map(buckets, & &1["name"])
        end

        # InfluxDB 2 pages the list; only its first 20 buckets used to be
        # returned (verified).
        test "list_buckets returns every bucket, past the server's page size", ctx do
          InfluxElixir.ClientContract.with_scratch_many(
            unquote(client),
            ctx,
            :bucket,
            "contract_page",
            101,
            fn names ->
              Enum.each(names, &(:ok = unquote(client).create_bucket(ctx.conn, &1, [])))

              {:ok, buckets} = unquote(client).list_buckets(ctx.conn)
              wanted = MapSet.new(names)
              listed = for %{"name" => name} <- buckets, name in wanted, do: name
              assert Enum.sort(listed) === Enum.sort(names)
            end
          )
        end

        test "list_buckets lists a created bucket as a user bucket with no expiry", ctx do
          InfluxElixir.ClientContract.with_scratch(
            unquote(client),
            ctx,
            :bucket,
            "contract_list_bkt",
            fn name ->
              :ok = unquote(client).create_bucket(ctx.conn, name, [])

              {:ok, buckets} = unquote(client).list_buckets(ctx.conn)
              assert Enum.all?(buckets, &is_map/1)

              assert [
                       %{
                         "name" => ^name,
                         "type" => "user",
                         "id" => id,
                         "orgID" => org_id,
                         "retentionRules" => [%{"type" => "expire", "everySeconds" => 0}]
                       }
                     ] = Enum.filter(buckets, &(&1["name"] === name))

              assert is_binary(id) and is_binary(org_id)
            end
          )
        end

        test "delete_bucket removes a bucket", ctx do
          InfluxElixir.ClientContract.with_scratch(
            unquote(client),
            ctx,
            :bucket,
            "contract_del_bkt",
            fn name ->
              :ok = unquote(client).create_bucket(ctx.conn, name, [])

              {:ok, before_delete} = unquote(client).list_buckets(ctx.conn)
              assert name in Enum.map(before_delete, & &1["name"])

              assert :ok === unquote(client).delete_bucket(ctx.conn, name)

              {:ok, after_delete} = unquote(client).list_buckets(ctx.conn)
              refute name in Enum.map(after_delete, & &1["name"])
            end
          )
        end

        test "a bucket created via create_bucket accepts writes", ctx do
          InfluxElixir.ClientContract.with_scratch(
            unquote(client),
            ctx,
            :bucket,
            "contract_write_bkt",
            fn name ->
              :ok = unquote(client).create_bucket(ctx.conn, name, [])

              assert {:ok, :written} =
                       unquote(client).write(
                         ctx.conn,
                         "contract_bkt_write value=1i",
                         database: name
                       )
            end
          )
        end

        test "a retention rule is stored in seconds; under one hour is refused", ctx do
          InfluxElixir.ClientContract.with_scratch(
            unquote(client),
            ctx,
            :bucket,
            "contract_ret",
            fn name ->
              :ok = unquote(client).create_bucket(ctx.conn, name, retention: 3600)

              {:ok, buckets} = unquote(client).list_buckets(ctx.conn)
              bucket = Enum.find(buckets, &(&1["name"] === name))
              assert [%{"type" => "expire", "everySeconds" => 3600}] = bucket["retentionRules"]

              assert {:error, %{status: 500, body: body}} =
                       unquote(client).create_bucket(ctx.conn, name <> "_short", retention: 60)

              assert %{"message" => "retention policy duration must be at least 1h0m0s"} =
                       Jason.decode!(body)
            end
          )
        end

        test "deleting a bucket that does not exist is a 404", ctx do
          name = InfluxElixir.IntegrationHelper.unique_name("contract_nobkt")

          assert {:error, %{status: 404, body: "bucket not found: " <> ^name}} =
                   unquote(client).delete_bucket(ctx.conn, name)
        end
      end
    end
  end

  defp v2_write_rule_tests(client) do
    quote location: :keep do
      describe "write/3 — v2 schema and partial-write contract" do
        test "a field type conflict is 422 with the dropped count; the other lines are stored",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_v2wr")

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m} v=1i 1700000000000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          lp = "#{m} v=2.0 1700000000000000001\n#{m} v=3i 1700000000000000002"

          assert {:error, %{status: 422, body: body}} =
                   unquote(client).write(ctx.conn, lp, database: ctx.database)

          assert %{"code" => "unprocessable entity", "message" => message} = Jason.decode!(body)

          assert message ===
                   "failure writing points to database: partial write: field type conflict: " <>
                     ~s|input field "v" on measurement "#{m}" is type float, already exists as | <>
                     "type integer dropped=1"

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_flux(
              ctx.conn,
              ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
            )

          assert Enum.map(rows, & &1["_value"]) === [1, 3]
        end

        test "every conflicting line counts in dropped, and each type pair is named", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_v2cf")

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m} v=1i 1700000000000000000",
              database: ctx.database
            )

          lp =
            "#{m} v=2.0 1700000000000000001\n#{m} v=3.0 1700000000000000002\n" <>
              "#{m} v=4i 1700000000000000003"

          assert {:error, %{status: 422, body: body}} =
                   unquote(client).write(ctx.conn, lp, database: ctx.database)

          assert Jason.decode!(body)["message"] ===
                   "failure writing points to database: partial write: field type conflict: " <>
                     ~s|input field "v" on measurement "#{m}" is type float, already exists as | <>
                     "type integer dropped=2"

          InfluxElixir.ClientContract.settle(ctx)

          flux =
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) | <>
              ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|

          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)
          assert Enum.map(rows, & &1["_value"]) === [1, 4]

          InfluxElixir.TestSupport.Check.each_case(
            [
              {"s", ~s|s="x"|, "s=1.0", "s", "string", "float"},
              {"b", "b=true", "b=1i", "b", "boolean", "integer"},
              {"u", "v=1i", "v=2u", "v", "integer", "unsigned"}
            ],
            fn {suffix, first, second, field, existing, got} ->
              name = "#{m}_#{suffix}"

              {:ok, :written} =
                unquote(client).write(ctx.conn, "#{name} #{first} 1700000000000000000",
                  database: ctx.database
                )

              assert {:error, %{status: 422, body: body}} =
                       unquote(client).write(ctx.conn, "#{name} #{second} 1700000000000000001",
                         database: ctx.database
                       )

              assert Jason.decode!(body)["message"] ===
                       "failure writing points to database: partial write: field type conflict: " <>
                         ~s|input field "#{field}" on measurement "#{name}" is type #{got}, | <>
                         "already exists as type #{existing} dropped=1"
            end
          )
        end

        # InfluxDB 2 stamps every untimed line of one write with the same
        # time (verified): lines of one series are one point, fields merged,
        # the last write winning.
        test "untimed lines of one write are one point per series", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_untimed")

          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "#{m},k=a v=1i\n#{m},k=a v=2i,w=9i\n#{m},k=b v=3i",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          flux =
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) | <>
              ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|

          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)

          assert rows |> Enum.map(&{&1["k"], &1["_field"], &1["_value"]}) |> Enum.sort() ===
                   [{"a", "v", 2}, {"a", "w", 9}, {"b", "v", 3}]

          assert [_one_time] = rows |> Enum.map(& &1["_time"]) |> Enum.uniq()
        end

        unquote(v2_write_rule_parse_tests(client))
      end
    end
  end

  defp v2_write_rule_parse_tests(client) do
    quote location: :keep do
      # InfluxDB 2 stores a string field that a \r follows, from after the
      # opening quote up to the \r, closing quote included; a number
      # followed by \r is refused (verified).
      test "a string field before a CRLF ending is stored, closing quote and all", ctx do
        m = InfluxElixir.IntegrationHelper.unique_name("contract_v2cr")

        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, "#{m} s=\"x\"\r\n#{m} s=\"y\"\r 5\n",
                   database: ctx.database,
                   precision: :nanosecond
                 )

        assert {:error, %{status: 400, body: body}} =
                 unquote(client).write(ctx.conn, "#{m} n=1i\r\n",
                   database: ctx.database,
                   precision: :nanosecond
                 )

        assert Jason.decode!(body) === %{
                 "code" => "invalid",
                 "message" => "unable to parse '#{m} n=1i\r': invalid number"
               }

        InfluxElixir.ClientContract.settle(ctx)

        flux =
          ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) | <>
            ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|

        {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)
        assert rows |> Enum.map(& &1["_value"]) |> Enum.sort() === ["x\"", "y\""]
      end

      test "a parse error rejects the whole payload with 400 and nothing is stored", ctx do
        m = InfluxElixir.IntegrationHelper.unique_name("contract_v2pe")
        lp = "#{m} v=1i 1700000000000000000\n#{m} v=\n#{m} v=3i 1700000000000000002"

        assert {:error, %{status: 400, body: body}} =
                 unquote(client).write(ctx.conn, lp, database: ctx.database)

        assert Jason.decode!(body) === %{
                 "code" => "invalid",
                 "message" => "unable to parse '#{m} v=': missing field value"
               }

        InfluxElixir.ClientContract.settle(ctx)

        {:ok, rows} =
          unquote(client).query_flux(
            ctx.conn,
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
          )

        assert rows === []
      end

      test "time as a tag key is 400", ctx do
        m = InfluxElixir.IntegrationHelper.unique_name("contract_v2t")

        assert {:error, %{status: 400, body: body}} =
                 unquote(client).write(ctx.conn, "#{m},time=x v=1i 1700000000000000000",
                   database: ctx.database
                 )

        assert Jason.decode!(body) === %{
                 "code" => "invalid",
                 "message" =>
                   "unable to parse '#{m},time=x v=1i 1700000000000000000': " <>
                     ~s|cannot use reserved tag key "time"|
               }
      end

      test "time as a field is dropped and the other fields are stored", ctx do
        m = InfluxElixir.IntegrationHelper.unique_name("contract_v2tf")

        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, "#{m} time=5i,v=1i 1700000000000000000",
                   database: ctx.database
                 )

        InfluxElixir.ClientContract.settle(ctx)

        {:ok, rows} =
          unquote(client).query_flux(
            ctx.conn,
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
          )

        assert Enum.map(rows, &{&1["_field"], &1["_value"]}) === [{"v", 1}]
      end

      test "a tag and a field may share a name: each row keeps its own", ctx do
        shared = InfluxElixir.IntegrationHelper.unique_name("contract_v2sh")

        InfluxElixir.TestSupport.Check.each_case(
          [
            "#{shared},host=a host=1i 1700000000000000000",
            "#{shared},host=b v=2i 1700000000000000001"
          ],
          fn line ->
            assert {:ok, :written} = unquote(client).write(ctx.conn, line, database: ctx.database)
          end
        )

        InfluxElixir.ClientContract.settle(ctx)

        {:ok, shared_rows} =
          unquote(client).query_flux(
            ctx.conn,
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{shared}")|
          )

        assert shared_rows |> Enum.map(&{&1["host"], &1["_field"], &1["_value"]}) |> Enum.sort() ===
                 [{"a", "host", 1}, {"b", "v", 2}]
      end

      test "an empty payload is accepted", ctx do
        assert {:ok, :written} = unquote(client).write(ctx.conn, "", database: ctx.database)
      end

      test "a payload of only a comment is accepted", ctx do
        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, "# only a comment\n", database: ctx.database)
      end

      # A backslash only escapes a comma, equals sign or space. `bs\\,t=a` is a
      # measurement holding a backslash and an escaped comma, which the engine
      # accepts (it does not return such a point to Flux, so none is read back);
      # `k\\=a` is a tag key `k\` with no value (verified).
      test "a doubled backslash before a comma is accepted; before = it is 400", ctx do
        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, ~S"bs\\,t=a v=1i 1700000000000000000",
                   database: ctx.database
                 )

        assert {:error, %{status: 400, body: body}} =
                 unquote(client).write(ctx.conn, ~S"bt,k\\=a v=2i 1700000000000000000",
                   database: ctx.database
                 )

        assert Jason.decode!(body) === %{
                 "code" => "invalid",
                 "message" =>
                   ~S"unable to parse 'bt,k\\=a v=2i 1700000000000000000': missing tag value"
               }
      end
    end
  end

  defp v2_precision_tests(client) do
    quote location: :keep do
      describe "write/3 — v2 precision contract" do
        test "ms and millisecond, as atoms or strings, mean milliseconds; the rest are 400",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_v2prec")

          InfluxElixir.TestSupport.Check.each_case(
            [:ms, "ms", :millisecond, "millisecond"],
            fn precision ->
              assert {:ok, :written} =
                       unquote(client).write(ctx.conn, "#{m} v=1i 1700000000000",
                         database: ctx.database,
                         precision: precision
                       )
            end
          )

          InfluxElixir.TestSupport.Check.each_case([:auto, :bogus, "NS"], fn precision ->
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, "#{m} v=1i 1",
                       database: ctx.database,
                       precision: precision
                     )

            assert Jason.decode!(body) === %{
                     "code" => "invalid",
                     "message" => "invalid precision; valid precision units are ns, us, ms, and s"
                   }
          end)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_flux(
              ctx.conn,
              ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
            )

          assert Enum.map(rows, & &1["_time"]) === [~U[2023-11-14 22:13:20.000000Z]]
        end
      end
    end
  end

  defp v2_duplicate_tests(client) do
    quote location: :keep do
      describe "write/3 — v2 duplicate point contract" do
        test "a point rewritten at the same tags and time merges, the later write winning",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_v2dup")

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},h=x v=1i,w=1i 1700000000000000000",
              database: ctx.database
            )

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},h=x v=2i 1700000000000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_flux(
              ctx.conn,
              ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
            )

          assert Enum.sort(Enum.map(rows, &{&1["_field"], &1["_value"]})) === [{"v", 2}, {"w", 1}]
        end
      end
    end
  end

  defp v2_body_tests(client) do
    quote location: :keep do
      describe "write/3 — v2 body contract" do
        test "a gzip body is read with gzip: true; a plain one then is the engine's 500", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_v2gz")

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, :zlib.gzip("#{m} v=1i 1"),
                     database: ctx.database,
                     gzip: true
                   )

          assert {:error, %{status: 500, body: body}} =
                   unquote(client).write(ctx.conn, "#{m} v=2i 2",
                     database: ctx.database,
                     gzip: true
                   )

          assert Jason.decode!(body) === %{
                   "code" => "internal error",
                   "message" => "An internal error has occurred - check server logs"
                 }

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"_value" => 1}]} =
                   unquote(client).query_flux(
                     ctx.conn,
                     ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
                   )
        end

        test "a body that is not UTF-8 is stored byte for byte", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_v2u8")

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "#{m},t=a\xFFb v=1i 1", database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"t" => "a\xFFb", "_value" => 1}]} =
                   unquote(client).query_flux(
                     ctx.conn,
                     ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
                   )
        end
      end
    end
  end
end
