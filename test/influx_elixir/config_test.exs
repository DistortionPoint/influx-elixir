defmodule InfluxElixir.ConfigTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Config

  # ---------------------------------------------------------------------------
  # validate/1
  # ---------------------------------------------------------------------------

  describe "validate/1 — required fields" do
    test "returns {:ok, opts} when both :host and :token are present" do
      assert {:ok, opts} = Config.validate(host: "localhost", token: "my-token")
      assert opts[:host] === "localhost"
      assert opts[:token] === "my-token"
    end

    test "returns {:error, validation_error} when :host is missing" do
      assert {:error,
              %NimbleOptions.ValidationError{
                key: :host,
                message: "required :host option not found" <> _rest
              }} =
               Config.validate(token: "my-token")
    end

    test "succeeds when :token is omitted (defaults to empty string)" do
      assert {:ok, opts} = Config.validate(host: "localhost")
      assert opts[:token] === ""
    end

    test "returns {:error, validation_error} when both required fields are missing" do
      assert {:error,
              %NimbleOptions.ValidationError{
                key: :host,
                message: "required :host option not found" <> _rest
              }} = Config.validate([])
    end
  end

  describe "validate/1 — defaults" do
    setup do
      {:ok, base_opts: [host: "localhost", token: "t"]}
    end

    test "applies :scheme default of :https", %{base_opts: base_opts} do
      assert {:ok, opts} = Config.validate(base_opts)
      assert opts[:scheme] === :https
    end

    test "applies :port default of 8086", %{base_opts: base_opts} do
      assert {:ok, opts} = Config.validate(base_opts)
      assert opts[:port] === 8086
    end

    test "applies :pool_size default of 10", %{base_opts: base_opts} do
      assert {:ok, opts} = Config.validate(base_opts)
      assert opts[:pool_size] === 10
    end

    test "applies :org default of empty string", %{base_opts: base_opts} do
      assert {:ok, opts} = Config.validate(base_opts)
      assert opts[:org] === ""
    end

    test ":database has no default and is absent when not provided", %{base_opts: base_opts} do
      assert {:ok, opts} = Config.validate(base_opts)
      refute Keyword.has_key?(opts, :database)
    end

    test "applies :api_version default of :v3", %{base_opts: base_opts} do
      assert {:ok, opts} = Config.validate(base_opts)
      assert opts[:api_version] === :v3
    end
  end

  describe "validate/1 — type validation" do
    test "rejects :scheme value that is not :http or :https" do
      assert {:error,
              %NimbleOptions.ValidationError{
                key: :scheme,
                message:
                  "invalid value for :scheme option: expected one of [:http, :https], got: :ftp"
              }} =
               Config.validate(host: "h", token: "t", scheme: :ftp)
    end

    test "accepts the supervisor-level keys and rejects unknown ones" do
      assert {:ok, opts} =
               Config.validate(
                 host: "h",
                 token: "t",
                 timeout: 5_000,
                 batch_writer: [batch_size: 10],
                 finch_name: :my_finch
               )

      assert opts[:batch_writer] === [batch_size: 10]

      # The typo that used to be silently ignored.
      assert {:error,
              %NimbleOptions.ValidationError{
                key: [:default_database],
                message: "unknown options [:default_database]" <> _rest
              }} =
               Config.validate(host: "h", token: "t", default_database: "prices")
    end

    test "accepts :api_version :v2 and rejects anything else" do
      assert {:ok, opts} = Config.validate(host: "h", token: "t", api_version: :v2)
      assert opts[:api_version] === :v2

      assert {:error,
              %NimbleOptions.ValidationError{
                key: :api_version,
                message:
                  "invalid value for :api_version option: expected one of [:v2, :v3], got: :v1"
              }} =
               Config.validate(host: "h", token: "t", api_version: :v1)
    end

    test "rejects a :port or :flight_port outside 1..65535" do
      for key <- [:port, :flight_port], port <- [-1, 0, 65_536] do
        assert {:error, %NimbleOptions.ValidationError{key: ^key, message: message}} =
                 Config.validate([{key, port}, host: "h"])

        assert message ===
                 "invalid value for #{inspect(key)} option: expected one of 1..65535, " <>
                   "got: #{port}"
      end

      assert {:ok, _opts} = Config.validate(host: "h", port: 65_535, flight_port: 1)
    end

    test "rejects :pool_size that is not a positive integer" do
      assert {:error,
              %NimbleOptions.ValidationError{
                key: :pool_size,
                message: "invalid value for :pool_size option: expected positive integer, got: 0"
              }} =
               Config.validate(host: "h", token: "t", pool_size: 0)
    end

    test "rejects :host that is not a string" do
      assert {:error,
              %NimbleOptions.ValidationError{
                key: :host,
                message:
                  "invalid value for :host option: expected :host to be a non-empty " <>
                    "string, got: 123"
              }} =
               Config.validate(host: 123, token: "t")
    end

    test "rejects an empty :host, or one with a blank or control character" do
      for host <- ["", "a b", "h\nx", "h\tx"] do
        assert {:error, %NimbleOptions.ValidationError{key: :host}} = Config.validate(host: host)
      end

      for host <- ["localhost", "[::1]", "10.0.0.1", "日本.jp"] do
        assert {:ok, _opts} = Config.validate(host: host)
      end
    end

    test "rejects :token that is not a string" do
      assert {:error,
              %NimbleOptions.ValidationError{
                key: :token,
                message: "invalid value for :token option: expected string, got: :not_a_string"
              }} =
               Config.validate(host: "h", token: :not_a_string)
    end

    test "accepts :scheme :http" do
      assert {:ok, opts} = Config.validate(host: "h", token: "t", scheme: :http)
      assert opts[:scheme] === :http
    end

    test "accepts :scheme :https" do
      assert {:ok, opts} = Config.validate(host: "h", token: "t", scheme: :https)
      assert opts[:scheme] === :https
    end
  end

  describe "validate/1 — explicit values override defaults" do
    test "explicit :port is preserved" do
      assert {:ok, opts} = Config.validate(host: "h", token: "t", port: 9999)
      assert opts[:port] === 9999
    end

    test "explicit :pool_size is preserved" do
      assert {:ok, opts} = Config.validate(host: "h", token: "t", pool_size: 50)
      assert opts[:pool_size] === 50
    end

    test "explicit :org is preserved" do
      assert {:ok, opts} = Config.validate(host: "h", token: "t", org: "my-org")
      assert opts[:org] === "my-org"
    end

    test "explicit :database is preserved" do
      assert {:ok, opts} = Config.validate(host: "h", token: "t", database: "metrics")
      assert opts[:database] === "metrics"
    end
  end

  # ---------------------------------------------------------------------------
  # validate!/1
  # ---------------------------------------------------------------------------

  describe "validate!/1" do
    test "returns keyword list for valid opts" do
      opts = Config.validate!(host: "localhost", token: "my-token")
      assert opts[:host] === "localhost"
      # Defaults are filled in, as validate/1 does.
      assert opts[:scheme] === :https and opts[:port] === 8086
    end

    test "raises NimbleOptions.ValidationError for missing :host" do
      assert_raise NimbleOptions.ValidationError, ~r/required :host option not found/, fn ->
        Config.validate!(token: "my-token")
      end
    end

    test "succeeds when :token is omitted" do
      opts = Config.validate!(host: "localhost")
      assert opts[:token] === ""
    end

    test "raises NimbleOptions.ValidationError for invalid :scheme" do
      assert_raise NimbleOptions.ValidationError, ~r/invalid value for :scheme option/, fn ->
        Config.validate!(host: "h", token: "t", scheme: :ws)
      end
    end

    test "raises NimbleOptions.ValidationError for zero :pool_size" do
      assert_raise NimbleOptions.ValidationError, ~r/invalid value for :pool_size option/, fn ->
        Config.validate!(host: "h", token: "t", pool_size: 0)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # base_url/1
  # ---------------------------------------------------------------------------

  describe "base_url/1" do
    test "builds https URL with custom port" do
      opts = [scheme: :https, host: "example.com", port: 443]
      assert Config.base_url(opts) === "https://example.com:443"
    end

    test "builds http URL with default port" do
      opts = [scheme: :http, host: "localhost", port: 8086]
      assert Config.base_url(opts) === "http://localhost:8086"
    end

    test "includes non-standard port in URL" do
      opts = [scheme: :https, host: "us-east-1.influxdb.io", port: 9999]
      assert Config.base_url(opts) === "https://us-east-1.influxdb.io:9999"
    end

    test "builds URL for IP address host" do
      opts = [scheme: :http, host: "192.168.1.100", port: 8086]
      assert Config.base_url(opts) === "http://192.168.1.100:8086"
    end

    test "scheme atom is rendered without quotes in URL" do
      opts = [scheme: :http, host: "h", port: 80]
      url = Config.base_url(opts)
      assert String.starts_with?(url, "http://")
    end

    test "works with opts produced by validate!/1" do
      validated = Config.validate!(host: "myhost.io", token: "tok", scheme: :https, port: 443)
      assert Config.base_url(validated) === "https://myhost.io:443"
    end
  end
end
