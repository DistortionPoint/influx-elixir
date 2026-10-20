defmodule InfluxElixir.Client.Local.Admin do
  @moduledoc false
  # The admin path of `InfluxElixir.Client.Local`: databases (v3), buckets (v2),
  # tokens and health. `Client.Local` is the public entry point and checks the
  # profile's capabilities before it calls here.

  alias InfluxElixir.Admin.TokenRequest
  alias InfluxElixir.Client.Local.{Buckets, DatabaseRules, Format, Retention, Scope, Store}

  @spec create_database(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_database(%{table: table} = conn, name, opts) do
    with :ok <- Scope.require_capability(conn, :create_database),
         :ok <- utf8_name(name, "database"),
         {:ok, retention} <- retention(Keyword.get(opts, :retention), name) do
      Store.create_database(
        table,
        name,
        &DatabaseRules.check_new(name, &1, conn.profile),
        retention
      )
    end
  end

  # `retention:` is sent as the engine's `retention_period`, a duration
  # string it reads before anything else in the request (verified against
  # InfluxDB 3 Core; the grammar and what the double does with the period
  # are in `Retention`). It is read as the JSON `Client.HTTP` sends: an atom
  # is a string there, as is a struct Jason encodes as one. Anything else is
  # the engine's JSON error (see `serde_error/4`). Without a `retention:` the
  # database has none.
  @spec retention(term(), binary()) :: {:ok, Retention.t()} | {:error, term()}
  defp retention(nil, _name), do: {:ok, nil}

  defp retention(retention, name) do
    case Jason.encode(%{"db" => name, "retention_period" => retention}) do
      {:ok, body} ->
        json = Jason.encode!(retention)

        case Jason.decode!(json) do
          text when is_binary(text) ->
            if Retention.valid?(text),
              do: {:ok, Retention.seconds(text)},
              else: serde_error(~s|invalid value: string "#{text}"|, json, body, "a duration")

          sent ->
            serde_error(unexpected(sent), json, body, "a duration")
        end

      # JSON holds only UTF-8 text: no engine answer exists for a retention that is not.
      {:error, _unencodable} when is_binary(retention) ->
        {:error, %{status: 400, body: "Client.Local: the retention is not valid UTF-8"}}

      {:error, error} ->
        {:error, {:unencodable_body, Exception.message(error)}}
    end
  rescue
    error in [FunctionClauseError, Protocol.UndefinedError, Jason.EncodeError, ArgumentError] ->
      {:error, {:unencodable_body, Exception.message(error)}}
  end

  # The engine's JSON parser (serde_json) refuses a value of the wrong type with a 400 that
  # names it, at `line 1 column N`: `json` is the value as sent, the body's last, so a scalar
  # ends at the byte before the closing brace, while a list or a map is refused at the byte
  # before it starts. A number beyond a float is an error of its own. (All verified on Core
  # 3.10.1, for `retention_period` and `expiry_secs` alike.)
  @typep what :: binary() | {binary(), :start} | :out_of_range

  @spec serde_error(what(), binary(), binary(), binary()) ::
          {:error, map()}
  defp serde_error(what, json, body, expected) do
    finish = byte_size(body) - 1
    start = finish - byte_size(json)

    message =
      case what do
        :out_of_range -> "number out of range at line 1 column #{finish}"
        {what, :start} -> "#{what}, expected #{expected} at line 1 column #{start}"
        what -> "#{what}, expected #{expected} at line 1 column #{finish}"
      end

    {:error, %{status: 400, body: "serde json error: " <> message}}
  end

  @min_i64 -0x8000000000000000
  @max_u64 0xFFFFFFFFFFFFFFFF

  # How serde names a JSON value its target type cannot take. An integer outside both i64
  # and u64 is parsed as a float, and one beyond every float is out of range.
  @spec unexpected(term()) :: what()
  defp unexpected(value) when is_boolean(value), do: "invalid type: boolean `#{value}`"
  defp unexpected(value) when is_binary(value), do: ~s|invalid type: string "#{value}"|
  defp unexpected(value) when is_list(value), do: {"invalid type: sequence", :start}
  defp unexpected(value) when is_map(value), do: {"invalid type: map", :start}

  defp unexpected(value) when is_float(value),
    do: "invalid type: floating point `#{Format.render_serde_float(value)}`"

  defp unexpected(value) when value in @min_i64..@max_u64, do: "invalid type: integer `#{value}`"

  defp unexpected(value) do
    unexpected(:erlang.float(value))
  rescue
    ArgumentError -> :out_of_range
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
         :ok <- utf8_name(name, "database"),
         :ok <- deletable(name) do
      # Dropping a database drops its tables: points and schema go with it,
      # so a re-created database starts empty.
      case Store.drop_database(table, name) do
        :ok -> :ok
        :error -> {:error, %{status: 404, body: "the requested resource was not found: #{name}"}}
      end
    end
  end

  # A name is written into a JSON body or a URL, which only UTF-8 text can be, so no
  # engine answer exists for one that is not: the double refuses it by name.
  @spec utf8_name(binary(), binary()) :: :ok | {:error, map()}
  defp utf8_name(name, kind) when is_binary(name) do
    if String.valid?(name),
      do: :ok,
      else: {:error, %{status: 400, body: "Client.Local: the #{kind} name is not valid UTF-8"}}
  end

  # No engine answer exists for a name that is not text: refused by name, never raised.
  defp utf8_name(_name, kind),
    do: {:error, %{status: 400, body: "Client.Local: the #{kind} name is not a string"}}

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
  def create_bucket(%{table: table} = conn, name, opts) do
    with :ok <- Scope.require_capability(conn, :create_bucket),
         :ok <- utf8_name(name, "bucket") do
      # InfluxDB 2.7's order (verified): the value's type, its sign, the name (a bucket that
      # exists is a 422 conflict, which `Client.HTTP` answers `:ok`, the bucket kept as it
      # was), then the hour's minimum. `nil` is sent as JSON null, which 2.7 reads as 0;
      # `false` is a boolean to it, refused as any other value that is not a number.
      case Keyword.get(opts, :retention) do
        nil ->
          create_new_bucket(table, name, 0)

        seconds when not is_integer(seconds) ->
          {:error,
           %{
             status: 400,
             body:
               "Client.Local: retention: must be a whole number of seconds, " <>
                 "got #{inspect(seconds)}"
           }}

        seconds when seconds < 0 ->
          v2_error(422, "unprocessable entity", "expiration seconds cannot be negative")

        seconds ->
          create_new_bucket(table, name, seconds)
      end
    end
  end

  @spec create_new_bucket(Store.t(), binary(), non_neg_integer()) :: :ok | {:error, map()}
  defp create_new_bucket(table, name, seconds) do
    cond do
      Store.bucket?(table, name) ->
        :ok

      seconds in 1..3599 ->
        v2_error(500, "internal error", "retention policy duration must be at least 1h0m0s")

      true ->
        # One insert: of two creates of a new name one registers it, the other is the
        # conflict, `:ok` as above.
        Store.put_new_bucket(table, name, %{
          retention: seconds,
          created_at: nanosecond_timestamp()
        })

        :ok
    end
  end

  @spec v2_error(pos_integer(), binary(), binary()) :: {:error, map()}
  defp v2_error(status, code, message) do
    {:error, %{status: status, body: Jason.encode!(%{"code" => code, "message" => message})}}
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
          bucket_map(name, seconds, org_id, meta.created_at)
        end)

      {:ok, bkts}
    end
  end

  @spec delete_bucket(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_bucket(%{table: table} = conn, name) do
    with :ok <- Scope.require_capability(conn, :delete_bucket),
         :ok <- utf8_name(name, "bucket") do
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
  def create_token(%{table: table, profile: profile} = conn, name, opts) do
    with :ok <- Scope.require_capability(conn, :create_token),
         :ok <- utf8_name(name, "token"),
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

  # `expiry_secs` is a u64 to the engine, read as the JSON the request carries (the last key
  # of `body`); anything else is its JSON error (see `serde_error/4`). A negative integer
  # is an i64, a value of the right type that a u64 cannot hold.
  @spec check_expiry(term(), binary()) ::
          {:ok, non_neg_integer() | nil} | {:error, map()}
  defp check_expiry(nil, _body), do: {:ok, nil}

  defp check_expiry(secs, body) do
    json = Jason.encode!(secs)

    case Jason.decode!(json) do
      sent when is_integer(sent) and sent in 0..@max_u64 ->
        {:ok, sent}

      sent when is_integer(sent) and sent in @min_i64..-1//1 ->
        serde_error("invalid value: integer `#{sent}`", json, body, "u64")

      sent ->
        serde_error(unexpected(sent), json, body, "u64")
    end
  end

  @unix_epoch :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

  # The last instant the engine's calendar (chrono) holds, in milliseconds: an expiry past it
  # is `null`, as if the token never expired (verified: `+262142-12-31T23:59:59.098Z` is
  # printed, a second later is `null`, and so is any `expiry_secs` up to u64's last).
  @latest_ms (:calendar.datetime_to_gregorian_seconds({{262_142, 12, 31}, {23, 59, 59}}) -
                @unix_epoch) * 1000 + 999

  @spec new_token(pos_integer(), binary(), non_neg_integer() | nil) :: map()
  defp new_token(id, name, expiry_secs) do
    created = System.os_time(:millisecond)
    secret = "apiv3_" <> Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false)

    %{
      "id" => id,
      "name" => name,
      "token" => secret,
      "hash" => :sha512 |> :crypto.hash(secret) |> Base.encode16(case: :lower),
      "created_at" => token_time(created),
      "expiry" => expiry(created, expiry_secs)
    }
  end

  @spec expiry(integer(), non_neg_integer() | nil) :: binary() | nil
  defp expiry(_created, nil), do: nil

  defp expiry(created, secs) do
    at = created + secs * 1000
    if at <= @latest_ms, do: token_time(at)
  end

  @doc false
  # A time in Unix milliseconds as the engine prints a token's: to the millisecond, with no
  # fraction at all when the milliseconds are zero (`…:53Z`), and a year past 9999 signed
  # (`+10056-10-16T17:45:45.943Z`; all verified against Core). Public only so the cases a
  # created token reaches by chance (a whole second) can be tested directly.
  @spec token_time(non_neg_integer()) :: binary()
  def token_time(ms) do
    {{year, month, day}, {hour, minute, second}} =
      :calendar.gregorian_seconds_to_datetime(div(ms, 1000) + @unix_epoch)

    year = if year > 9999, do: "+#{year}", else: pad(year, 4)

    fraction =
      case rem(ms, 1000) do
        0 -> ""
        milliseconds -> "." <> pad(milliseconds, 3)
      end

    "#{year}-#{pad(month, 2)}-#{pad(day, 2)}T#{pad(hour, 2)}:#{pad(minute, 2)}:" <>
      "#{pad(second, 2)}#{fraction}Z"
  end

  @spec pad(non_neg_integer(), pos_integer()) :: binary()
  defp pad(number, width), do: number |> Integer.to_string() |> String.pad_leading(width, "0")

  @spec delete_token(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_token(%{table: table} = conn, name) do
    with :ok <- Scope.require_capability(conn, :delete_token),
         :ok <- utf8_name(name, "token") do
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
