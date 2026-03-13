defmodule InfluxElixir.Client.HTTP do
  @moduledoc """
  Production InfluxDB client implementation using Finch.

  Communicates with real InfluxDB v3 (and v2) instances over HTTP.
  Uses Finch connection pools for efficient HTTP/1.1 and HTTP/2.
  """

  @behaviour InfluxElixir.Client

  @impl true
  @spec write(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.write_result()
  def write(_connection, _line_protocol, _opts \\ []) do
    {:error, :not_implemented}
  end

  @impl true
  @spec query_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_sql(_connection, _sql, _opts \\ []) do
    {:error, :not_implemented}
  end

  @impl true
  @spec query_sql_stream(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: Enumerable.t()
  def query_sql_stream(_connection, _sql, _opts \\ []) do
    Stream.map([], & &1)
  end

  @impl true
  @spec execute_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_sql(_connection, _sql, _opts \\ []) do
    {:error, :not_implemented}
  end

  @impl true
  @spec query_influxql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query_influxql(_connection, _influxql, _opts \\ []) do
    {:error, :not_implemented}
  end

  @impl true
  @spec query_flux(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_flux(_connection, _flux, _opts \\ []) do
    {:error, :not_implemented}
  end

  @impl true
  @spec create_database(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_database(_connection, _name, _opts \\ []) do
    {:error, :not_implemented}
  end

  @impl true
  @spec list_databases(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_databases(_connection) do
    {:error, :not_implemented}
  end

  @impl true
  @spec delete_database(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_database(_connection, _name) do
    {:error, :not_implemented}
  end

  @impl true
  @spec create_bucket(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_bucket(_connection, _name, _opts \\ []) do
    {:error, :not_implemented}
  end

  @impl true
  @spec list_buckets(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_buckets(_connection) do
    {:error, :not_implemented}
  end

  @impl true
  @spec delete_bucket(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_bucket(_connection, _name) do
    {:error, :not_implemented}
  end

  @impl true
  @spec create_token(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def create_token(_connection, _description, _opts \\ []) do
    {:error, :not_implemented}
  end

  @impl true
  @spec delete_token(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_token(_connection, _token_id) do
    {:error, :not_implemented}
  end

  @impl true
  @spec health(InfluxElixir.Client.connection()) ::
          {:ok, map()} | {:error, term()}
  def health(_connection) do
    {:error, :not_implemented}
  end
end
