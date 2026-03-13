defmodule InfluxElixir.Connection do
  @moduledoc """
  Named connection manager for InfluxDB instances.

  Stores and retrieves validated connection configuration keyed by name.
  Connection configs are stored in a persistent term for fast, lock-free
  reads from any process.

  ## Usage

  Connections are typically registered by `InfluxElixir.ConnectionSupervisor`
  during startup. Consumer code looks up connections by name:

      config = InfluxElixir.Connection.get(:my_influx)
      InfluxElixir.Client.HTTP.write(config, "cpu value=1.0")

  ## Storage

  Uses `:persistent_term` for near-zero-cost reads. Writes happen only
  during connection setup/teardown (rare), so the copy-on-write cost
  of `:persistent_term` is acceptable.
  """

  @doc """
  Stores a validated connection config under the given name.

  ## Parameters

    * `name` - atom identifying the connection
    * `config` - keyword list of validated connection options

  ## Examples

      iex> InfluxElixir.Connection.put(:test, host: "localhost", token: "t")
      :ok
  """
  @spec put(atom(), keyword()) :: :ok
  def put(name, config) when is_atom(name) do
    :persistent_term.put({__MODULE__, name}, config)
    :ok
  end

  @doc """
  Retrieves the connection config for the given name.

  Returns `{:ok, config}` or `{:error, :not_found}`.

  ## Parameters

    * `name` - atom identifying the connection

  ## Examples

      iex> InfluxElixir.Connection.put(:test, host: "localhost", token: "t")
      iex> {:ok, config} = InfluxElixir.Connection.get(:test)
      iex> config[:host]
      "localhost"
  """
  @spec get(atom()) :: {:ok, keyword()} | {:error, :not_found}
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
      iex> config = InfluxElixir.Connection.fetch!(:test)
      iex> config[:host]
      "localhost"
  """
  @spec fetch!(atom()) :: keyword()
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
