defmodule InfluxElixir.Connection do
  @moduledoc """
  Named connection manager for InfluxDB instances.

  Stores and retrieves **initialized connections** keyed by name.
  Values are stored in a persistent term for fast, lock-free reads
  from any process.

  ## Important

  Stored values are **initialized connections** (the result of
  `Client.init_connection/1`), not raw keyword configs. The type
  depends on the configured client implementation:

  - `Client.HTTP` — keyword list (host, token, etc.)
  - `Client.Local` — map with ETS table reference (`%{table: _, databases: _, profile: _}`)

  ## Usage

  Connections are automatically registered by
  `InfluxElixir.ConnectionSupervisor` during startup. The supervisor
  calls `Client.init_connection/1` to convert raw config into a
  usable connection before storing it here. The facade module
  (`InfluxElixir`) resolves atom names transparently, so most consumer
  code simply passes the connection name:

      InfluxElixir.health(:trading)
      InfluxElixir.write(:trading, "cpu value=1.0", database: "prices")

  For direct registry access:

      {:ok, conn} = InfluxElixir.Connection.get(:trading)
      conn = InfluxElixir.Connection.fetch!(:trading)

  ## Storage

  Uses `:persistent_term` for near-zero-cost reads. Writes happen only
  during connection setup/teardown (rare), so the copy-on-write cost
  of `:persistent_term` is acceptable.
  """

  @doc """
  Stores a validated connection config under the given name.

  ## Parameters

    * `name` - atom identifying the connection
    * `connection` - initialized connection value (from `Client.init_connection/1`)

  ## Examples

      iex> InfluxElixir.Connection.put(:test, host: "localhost", token: "t")
      :ok
  """
  @spec put(atom(), term()) :: :ok
  def put(name, connection) when is_atom(name) do
    :persistent_term.put({__MODULE__, name}, connection)
    :ok
  end

  @doc """
  Retrieves the connection config for the given name.

  Returns `{:ok, connection}` or `{:error, :not_found}`.

  ## Parameters

    * `name` - atom identifying the connection

  ## Examples

      iex> InfluxElixir.Connection.put(:test, host: "localhost", token: "t")
      iex> {:ok, conn} = InfluxElixir.Connection.get(:test)
      iex> conn[:host]
      "localhost"
  """
  @spec get(atom()) :: {:ok, term()} | {:error, :not_found}
  def get(name) when is_atom(name) do
    {:ok, :persistent_term.get({__MODULE__, name})}
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @doc """
  Retrieves the connection config for the given name, raising on miss.

  ## Parameters

    * `name` - atom identifying the connection

  ## Examples

      iex> InfluxElixir.Connection.put(:test, host: "localhost", token: "t")
      iex> conn = InfluxElixir.Connection.fetch!(:test)
      iex> conn[:host]
      "localhost"
  """
  @spec fetch!(atom()) :: term()
  def fetch!(name) when is_atom(name) do
    :persistent_term.get({__MODULE__, name})
  end

  @doc """
  Removes a connection config by name.

  Returns `:ok` regardless of whether the name existed.

  ## Parameters

    * `name` - atom identifying the connection
  """
  @spec delete(atom()) :: :ok
  def delete(name) when is_atom(name) do
    :persistent_term.erase({__MODULE__, name})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Returns the Finch pool name for a given connection name.

  This is a convenience wrapper around
  `InfluxElixir.ConnectionSupervisor.finch_name/1`.

  ## Parameters

    * `name` - atom identifying the connection
  """
  @spec finch_name(atom()) :: atom()
  def finch_name(name) when is_atom(name) do
    InfluxElixir.ConnectionSupervisor.finch_name(name)
  end
end
