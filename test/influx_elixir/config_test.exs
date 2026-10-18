defmodule InfluxElixir.ConfigTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Config
  alias NimbleOptions.ValidationError

  # The examples in the docs run; none touches global state.
  doctest InfluxElixir.Config

  # The options the schema fills in when they are not given.
  @defaults %{
    token: "",
    org: "",
    databases: [],
    port: 8086,
    scheme: :https,
    pool_size: 10,
    api_version: :v3
  }

  # A validated config holds each key once, so its map is all of it.
  defp validated(opts) do
    {:ok, validated} = Config.validate(opts)
    Map.new(validated)
  end

  defp host_error(host, message) do
    {:error,
     %ValidationError{
       key: :host,
       value: host,
       message: "invalid value for :host option: " <> message
     }}
  end

  # ---------------------------------------------------------------------------
  # validate/1
  # ---------------------------------------------------------------------------

  describe "validate/1 — given values and defaults" do
    test "fills in every default, and only those, around :host" do
      assert validated(host: "localhost") === Map.put(@defaults, :host, "localhost")
    end

    test "keeps every value given" do
      given = [
        host: "h",
        token: "t",
        org: "my-org",
        database: "metrics",
        databases: ["a", "b"],
        port: 9999,
        scheme: :http,
        pool_size: 50,
        api_version: :v2,
        timeout: 5_000,
        pool_timeout: 1_000,
        flight_port: 8181,
        batch_writer: [batch_size: 10],
        finch_name: :my_finch,
        name: :conn
      ]

      assert validated(given) === Map.new(given)
    end

    test ":host is required" do
      for {opts, received} <- [{[token: "my-token"], "[:token]"}, {[], "[]"}] do
        assert Config.validate(opts) ===
                 {:error,
                  %ValidationError{
                    key: :host,
                    message: "required :host option not found, received options: " <> received
                  }}
      end
    end
  end

  describe "validate/1 — type validation" do
    test "rejects an unknown option, as the typo that used to be silently ignored" do
      assert {:error, %ValidationError{key: [:default_database], value: nil, message: message}} =
               Config.validate(host: "h", default_database: "prices")

      assert message ===
               "unknown options [:default_database], valid options are: " <>
                 "[:host, :token, :org, :database, :databases, :port, :scheme, :pool_size, " <>
                 ":api_version, :timeout, :pool_timeout, :flight_port, :batch_writer, " <>
                 ":finch_name, :name]"
    end

    test "rejects a value outside its type, naming it" do
      for {key, value, expected} <- [
            {:scheme, :ftp, "expected one of [:http, :https], got: :ftp"},
            {:api_version, :v1, "expected one of [:v2, :v3], got: :v1"},
            {:pool_size, 0, "expected positive integer, got: 0"},
            {:timeout, :infinity, "expected positive integer, got: :infinity"},
            {:pool_timeout, 0, "expected positive integer, got: 0"},
            {:token, :not_a_string, "expected string, got: :not_a_string"},
            {:token, nil, "expected string, got: nil"},
            {:org, 1, "expected string, got: 1"},
            {:database, 1, "expected string, got: 1"},
            {:databases, "x", "expected list, got: \"x\""},
            {:batch_writer, [1], "expected keyword list, got: [1]"},
            {:finch_name, "f", "expected atom, got: \"f\""},
            {:name, "n", "expected atom, got: \"n\""}
          ] do
        assert Config.validate([{key, value}, host: "h"]) ===
                 {:error,
                  %ValidationError{
                    key: key,
                    value: value,
                    message: "invalid value for #{inspect(key)} option: " <> expected
                  }},
               inspect({key, value})
      end
    end

    test "rejects a :port or :flight_port outside 1..65535" do
      for key <- [:port, :flight_port], port <- [-1, 0, 65_536] do
        assert Config.validate([{key, port}, host: "h"]) ===
                 {:error,
                  %ValidationError{
                    key: key,
                    value: port,
                    message:
                      "invalid value for #{inspect(key)} option: expected one of 1..65535, " <>
                        "got: #{port}"
                  }}
      end

      assert validated(host: "h", port: 65_535, flight_port: 1) ===
               Map.merge(@defaults, %{host: "h", port: 65_535, flight_port: 1})
    end

    test "options that are not a keyword list are a validation error, from both functions" do
      for opts <- [
            "notalist",
            %{host: "h"},
            nil,
            [1, 2],
            [{"host", "x"}],
            [:host],
            [[host: "h"]],
            [{:host, "ok"} | :improper]
          ] do
        message = "expected the options to be a keyword list, got: #{inspect(opts)}"
        assert Config.validate(opts) === {:error, %ValidationError{message: message}}
        assert_raise ValidationError, message, fn -> Config.validate!(opts) end
      end
    end

    test "rejects a :host that is not a non-empty string" do
      for host <- [123, "", nil] do
        assert Config.validate(host: host) ===
                 host_error(
                   host,
                   "expected :host to be a non-empty string, got: #{inspect(host)}"
                 )
      end
    end

    # A host the request URL would read as something else sends the request elsewhere.
    test "accepts only a host the request URL reads back as its host" do
      for host <- [
            "a b",
            "h\nx",
            "h\tx",
            <<0xFF>>,
            "a" <> <<0xFF>> <> "b",
            "[fe80::1%en0]",
            "::1",
            "http://x",
            "x/y",
            "host:8086",
            "user@host",
            "h?x",
            "h#x",
            "[::1",
            "日本.jp"
          ] do
        assert Config.validate(host: host) ===
                 host_error(
                   host,
                   "expected :host to be a host name or an IP address (IPv6 in brackets), " <>
                     "got: #{inspect(host)}"
                 ),
               inspect(host)
      end

      for host <- ["localhost", "[::1]", "10.0.0.1", "xn--wgv71a.jp", "a.b."] do
        assert validated(host: host) === Map.put(@defaults, :host, host), host
      end
    end
  end

  # ---------------------------------------------------------------------------
  # validate!/1
  # ---------------------------------------------------------------------------

  describe "validate!/1" do
    test "returns what validate/1 returns for valid opts" do
      opts = [host: "localhost", token: "my-token"]
      assert {:ok, Config.validate!(opts)} === Config.validate(opts)
    end

    test "raises the error validate/1 returns" do
      for opts <- [[token: "my-token"], [host: "h", scheme: :ws], [host: "h", pool_size: 0]] do
        {:error, error} = Config.validate(opts)

        assert_raise ValidationError, Exception.message(error), fn ->
          Config.validate!(opts)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # base_url/1
  # ---------------------------------------------------------------------------

  describe "base_url/1" do
    test "builds scheme://host:port from the options" do
      for {opts, url} <- [
            {[scheme: :https, host: "example.com", port: 443], "https://example.com:443"},
            {[scheme: :http, host: "localhost", port: 8086], "http://localhost:8086"},
            {[scheme: :https, host: "us-east-1.influxdb.io", port: 9999],
             "https://us-east-1.influxdb.io:9999"},
            {[scheme: :http, host: "192.168.1.100", port: 80], "http://192.168.1.100:80"},
            {[scheme: :http, host: "[::1]", port: 8181], "http://[::1]:8181"}
          ] do
        assert Config.base_url(opts) === url
      end
    end

    test "works with opts produced by validate!/1" do
      validated = Config.validate!(host: "myhost.io", token: "tok", scheme: :https, port: 443)
      assert Config.base_url(validated) === "https://myhost.io:443"
    end

    test "a missing scheme or port is the default one the HTTP client has always used" do
      assert Config.base_url(host: "h") === "https://h:8086"
      assert Config.base_url(host: "h", scheme: :http) === "http://h:8086"
      assert Config.base_url(host: "h", port: 80) === "https://h:80"
    end
  end
end
