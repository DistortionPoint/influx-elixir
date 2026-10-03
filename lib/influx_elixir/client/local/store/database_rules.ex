defmodule InfluxElixir.Client.Local.DatabaseRules do
  @moduledoc false
  # InfluxDB 3's rules for database names and counts, as `Client.Local`
  # applies them to `create_database/3`, to a write that creates its database
  # and to `start/1` (all verified against InfluxDB 3 Core).
  #
  # A name is checked in the engine's order, each failure a 400 with the
  # engine's JSON body:
  #
  #   1. empty — `db name cannot be empty`
  #   2. not starting with an ASCII letter or digit — `db name did not start
  #      with a number or letter`
  #   3. any character other than ASCII letters, digits, `_`, `-` and `/` —
  #      `invalid character in database or rp name: ...`
  #   4. a `/` that does not split the name into two non-empty parts
  #      (`<db>/<rp>`, InfluxDB 1's retention policy) — `db name with invalid
  #      retention policy, ...`
  #
  # There is no length limit. InfluxDB 3 Core holds at most 5 databases
  # besides `_internal`; a sixth is a 422, whether created or written to. The
  # limit is applied to the `:v3_core` profile only — Enterprise's was not
  # verified.

  @internal "_internal"
  @core_limit 5

  @doc "The engine's own database: listed, never created, written or dropped."
  @spec internal() :: binary()
  def internal, do: @internal

  @doc """
  Checks a database that is about to be created — by `create_database/3` or
  by a write — for a store that already holds `existing`. A database that
  already exists passes whatever the limit.
  """
  @spec check_new(binary(), Enumerable.t(binary()), atom()) :: :ok | {:error, map()}
  def check_new(name, existing, profile) do
    cond do
      name in existing -> :ok
      (error = name_error(name)) != nil -> {:error, error}
      over_limit?(existing, profile) -> {:error, limit_error()}
      true -> :ok
    end
  end

  @doc """
  Checks the databases `Client.Local.start/1` pre-creates, raising
  `ArgumentError` with the engine's message for the first one it would
  refuse: a test that cannot run against the server should not pass
  against the double.
  """
  @spec check_start!([binary()], atom()) :: :ok
  def check_start!(names, profile), do: check_start!(names, [], profile)

  @spec check_start!([binary()], [binary()], atom()) :: :ok
  defp check_start!([], _existing, _profile), do: :ok

  defp check_start!([name | rest], existing, profile) do
    case check_new(name, existing, profile) do
      :ok -> check_start!(rest, [name | existing], profile)
      {:error, %{body: body}} -> raise ArgumentError, "Client.Local.start/1: #{name}: #{body}"
    end
  end

  @spec over_limit?(Enumerable.t(binary()), atom()) :: boolean()
  defp over_limit?(existing, :v3_core), do: Enum.count(existing) >= @core_limit
  defp over_limit?(_existing, _profile), do: false

  @spec limit_error() :: map()
  defp limit_error do
    %{
      status: 422,
      body:
        Jason.encode!(%{
          "error" => "Adding a new database would exceed limit of #{@core_limit} databases"
        })
    }
  end

  @spec name_error(binary()) :: map() | nil
  defp name_error(""), do: bad_name("db name cannot be empty")

  defp name_error(<<first, _rest::binary>> = name) do
    cond do
      not alphanumeric?(first) ->
        bad_name("db name did not start with a number or letter")

      not Enum.all?(:binary.bin_to_list(name), &(alphanumeric?(&1) or &1 in ~c"_-/")) ->
        bad_name(
          "invalid character in database or rp name: must be ASCII, containing only " <>
            "letters, numbers, underscores, or hyphens"
        )

      not valid_rp?(name) ->
        bad_name(
          "db name with invalid retention policy, if providing a retention policy name, " <>
            "must be of form '<db_name>/<rp_name>'"
        )

      true ->
        nil
    end
  end

  @spec valid_rp?(binary()) :: boolean()
  defp valid_rp?(name) do
    case String.split(name, "/") do
      [_db] -> true
      [db, rp] -> db != "" and rp != ""
      _more -> false
    end
  end

  @spec alphanumeric?(byte()) :: boolean()
  defp alphanumeric?(char), do: char in ?a..?z or char in ?A..?Z or char in ?0..?9

  @spec bad_name(binary()) :: map()
  defp bad_name(message), do: %{status: 400, body: Jason.encode!(%{"error" => message})}
end
