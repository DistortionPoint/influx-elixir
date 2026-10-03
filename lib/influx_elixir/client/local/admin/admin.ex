defmodule InfluxElixir.Client.Local.Admin do
  @moduledoc false
  # The admin path of `InfluxElixir.Client.Local`: databases (v3), buckets (v2),
  # tokens and health. `Client.Local` is the public entry point and checks the
  # profile's capabilities before it calls here.

  alias InfluxElixir.Admin.TokenRequest
  alias InfluxElixir.Client.Local.{Buckets, DatabaseRules, Scope, Store}

  @spec create_database(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_database(%{table: table} = conn, name, opts \\ []) do
    with :ok <- Scope.require_capability(conn, :create_database),
         :ok <- check_retention(Keyword.get(opts, :retention), name),
         :ok <-
           Store.create_database(table, name, &DatabaseRules.check_new(name, &1, conn.profile)) do
      :ok
    end
  end

  # `retention:` is sent as the engine's `retention_period`, a duration
  # string it reads before anything else in the request (verified against
  # InfluxDB 3 Core): one or more `<number><unit>` parts, optionally
  # spaced, a fraction allowed (`1.5h`), units case-sensitive (`M` months,
  # `m` minutes), or a bare `0`. Anything else is its 400, ending in the
  # `at line 1 column N` its JSON parser appends: the byte just before the
  # closing brace of the body `Client.HTTP` sends (verified). The double
  # stores no retention for a database: nothing expires.
  @duration_units ~w(nanos nsec ns usec us µs millis msec ms seconds second secs sec s
                     minutes minute mins min m hours hour hrs hr h days day d weeks week w
                     months month M years year y)
  @duration ~r/^\s*(?:0|(?:\d+(?:\.\d+)?\s*(?:#{Enum.join(@duration_units, "|")})\s*)+)\s*$/u

  @spec check_retention(term(), binary()) :: :ok | {:error, map()}
  defp check_retention(nil, _name), do: :ok

  defp check_retention(retention, name) when is_boolean(retention),
    do: retention_error("invalid type: boolean `#{retention}`", retention, name)

  defp check_retention(retention, name) when is_binary(retention) or is_atom(retention) do
    text = to_string(retention)

    if Regex.match?(@duration, text),
      do: :ok,
      else: retention_error(~s|invalid value: string "#{text}"|, retention, name)
  end

  defp check_retention(retention, name) when is_integer(retention),
    do: retention_error("invalid type: integer `#{retention}`", retention, name)

  defp check_retention(retention, name) when is_float(retention),
    do: retention_error("invalid type: floating point `#{retention}`", retention, name)

  defp check_retention(retention, name),
    do: retention_error("invalid type: `#{inspect(retention)}`", retention, name)

  @spec retention_error(binary(), term(), binary()) :: {:error, map()}
  defp retention_error(what, retention, name) do
    position =
      case Jason.encode(%{"db" => name, "retention_period" => retention}) do
        {:ok, body} -> " at line 1 column #{byte_size(body) - 1}"
        {:error, _unencodable} -> ""
      end

    {:error, %{status: 400, body: "serde json error: #{what}, expected a duration" <> position}}
  end

  @spec list_databases(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_databases(%{table: table} = conn) do
    with :ok <- Scope.require_capability(conn, :list_databases) do
      {:ok, Enum.map(Scope.database_names(table), &%{"name" => &1})}
    end
  end

  @spec delete_database(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_database(%{table: table} = conn, name) do
    with :ok <- Scope.require_capability(conn, :delete_database),
         :ok <- deletable(name) do
      # Dropping a database drops its tables: points and schema go with it,
      # so a re-created database starts empty.
      case Store.drop_database(table, name) do
        :ok -> :ok
        :error -> {:error, %{status: 404, body: "the requested resource was not found: #{name}"}}
      end
    end
  end

  # The engine's answer for its own database (verified).
  @spec deletable(binary()) :: :ok | {:error, map()}
  defp deletable("_internal"), do: {:error, %{status: 500, body: "cannot delete internal db"}}
  defp deletable(_name), do: :ok

  # ---------------------------------------------------------------------------
  # Bucket admin (v2 compat)
  # ---------------------------------------------------------------------------

  @spec create_bucket(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_bucket(%{table: table} = conn, name, opts \\ []) do
    with :ok <- Scope.require_capability(conn, :create_bucket) do
      case Keyword.get(opts, :retention, 0) do
        seconds when seconds in 1..3599 ->
          {:error,
           %{
             status: 500,
             body:
               Jason.encode!(%{
                 "code" => "internal error",
                 "message" => "retention policy duration must be at least 1h0m0s"
               })
           }}

        seconds ->
          created_at =
            case Store.bucket(table, name) do
              %{created_at: at} -> at
              _new -> nanosecond_timestamp()
            end

          Store.put_bucket(table, name, %{retention: seconds, created_at: created_at})
          :ok
      end
    end
  end

  @spec list_buckets(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_buckets(%{table: table} = conn) do
    with :ok <- Scope.require_capability(conn, :list_buckets) do
      org_id = Buckets.hex_id(Map.get(conn, :org, "local"))

      bkts =
        table
        |> Store.buckets()
        |> Enum.map(fn {name, %{retention: seconds} = meta} ->
          bucket_map(name, seconds, org_id, Map.get(meta, :created_at, nanosecond_timestamp()))
        end)

      {:ok, bkts}
    end
  end

  @spec delete_bucket(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_bucket(%{table: table} = conn, name) do
    with :ok <- Scope.require_capability(conn, :delete_bucket) do
      case Store.delete_bucket(table, name) do
        :ok -> :ok
        :error -> {:error, %{status: 404, body: "bucket not found: #{name}"}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Token admin
  # ---------------------------------------------------------------------------

  @spec create_token(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def create_token(%{table: table, profile: profile} = conn, name, opts \\ []) do
    with :ok <- Scope.require_capability(conn, :create_token),
         {:ok, {kind, _path, body}} <- TokenRequest.build(name, opts),
         :ok <- token_endpoint(kind, profile),
         {:ok, expiry_secs} <- check_expiry(Keyword.get(opts, :expiry_secs), body) do
      case Store.create_token(table, name, &new_token(&1, name, expiry_secs)) do
        {:ok, token} ->
          {:ok, token}

        :exists ->
          {:error, %{status: 409, body: "token name already exists, #{name}"}}
      end
    end
  end

  @spec token_endpoint(TokenRequest.kind(), InfluxElixir.Client.Local.profile()) ::
          :ok | {:error, map()}
  defp token_endpoint(:resource, profile) when profile != :v3_enterprise,
    do: {:error, %{status: 404, body: "Not found"}}

  defp token_endpoint(_kind, _profile), do: :ok

  # `expiry_secs` is a u64 to the engine; anything else is its JSON error,
  # at the end of the value — the last key of the body (verified).
  @spec check_expiry(term(), binary()) :: {:ok, non_neg_integer() | nil} | {:error, map()}
  defp check_expiry(nil, _body), do: {:ok, nil}
  defp check_expiry(secs, _body) when is_integer(secs) and secs >= 0, do: {:ok, secs}

  defp check_expiry(secs, body) do
    what =
      cond do
        is_integer(secs) -> "invalid value: integer `#{secs}`"
        is_float(secs) -> "invalid type: floating point `#{secs}`"
        is_boolean(secs) -> "invalid type: boolean `#{secs}`"
        is_binary(secs) -> ~s|invalid type: string "#{secs}"|
        true -> "invalid type: `#{inspect(secs)}`"
      end

    {:error,
     %{
       status: 400,
       body: "serde json error: #{what}, expected u64 at line 1 column #{byte_size(body) - 1}"
     }}
  end

  @spec new_token(pos_integer(), binary(), non_neg_integer() | nil) :: map()
  defp new_token(id, name, expiry_secs) do
    created = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    secret = "apiv3_" <> Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false)

    %{
      "id" => id,
      "name" => name,
      "token" => secret,
      "hash" => :sha512 |> :crypto.hash(secret) |> Base.encode16(case: :lower),
      "created_at" => DateTime.to_iso8601(created),
      "expiry" => expiry_secs && DateTime.to_iso8601(DateTime.add(created, expiry_secs))
    }
  end

  @spec delete_token(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_token(%{table: table} = conn, name) do
    with :ok <- Scope.require_capability(conn, :delete_token) do
      cond do
        name == "_admin" ->
          {:error, %{status: 405, body: "cannot delete operator token"}}

        Store.delete_token(table, name) == :ok ->
          :ok

        true ->
          {:error, %{status: 404, body: "the requested resource was not found: #{name}"}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Health
  # ---------------------------------------------------------------------------

  @spec health(InfluxElixir.Client.connection()) ::
          {:ok, map()} | {:error, term()}
  def health(conn) do
    with :ok <- Scope.require_capability(conn, :health) do
      {:ok, health_body(conn.profile)}
    end
  end

  @spec health_body(InfluxElixir.Client.Local.profile()) :: map()
  defp health_body(:v2) do
    %{
      "name" => "influxdb",
      "message" => "ready for queries and writes",
      "status" => "pass",
      "checks" => [],
      "version" => "local",
      "commit" => "local"
    }
  end

  defp health_body(_v3), do: %{"status" => "pass"}

  @spec bucket_map(binary(), non_neg_integer(), binary(), binary()) :: map()
  defp bucket_map(name, retention, org_id, created_at) do
    id = Buckets.hex_id(name)
    base = "/api/v2/buckets/#{id}"

    %{
      "id" => id,
      "orgID" => org_id,
      "type" => "user",
      "name" => name,
      "retentionRules" => [
        %{
          "type" => "expire",
          "everySeconds" => retention,
          "shardGroupDurationSeconds" => Buckets.shard_group_seconds(retention)
        }
      ],
      "createdAt" => created_at,
      "updatedAt" => created_at,
      "links" => %{
        "labels" => base <> "/labels",
        "members" => base <> "/members",
        "org" => "/api/v2/orgs/#{org_id}",
        "owners" => base <> "/owners",
        "self" => base,
        "write" => "/api/v2/write?org=#{org_id}&bucket=#{id}"
      },
      "labels" => []
    }
  end

  # The engine's timestamps: RFC 3339 with nine fractional digits.
  @spec nanosecond_timestamp() :: binary()
  defp nanosecond_timestamp do
    ns = System.os_time(:nanosecond)
    seconds = Integer.floor_div(ns, 1_000_000_000)
    stamp = seconds |> DateTime.from_unix!() |> DateTime.to_iso8601() |> String.trim_trailing("Z")

    stamp <>
      "." <> String.pad_leading(Integer.to_string(Integer.mod(ns, 1_000_000_000)), 9, "0") <> "Z"
  end
end
