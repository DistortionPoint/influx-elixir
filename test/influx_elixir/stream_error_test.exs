defmodule InfluxElixir.StreamErrorTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.StreamError

  describe "exception/1" do
    test "builds a :no_database error with a helpful message" do
      error = StreamError.exception(kind: :no_database)

      assert error.kind === :no_database

      assert Exception.message(error) ===
               "no database specified for streaming query: pass `database:` in opts " <>
                 "or set `:database` on the connection"
    end

    test "builds an :http_status error carrying status and body" do
      error = StreamError.exception(kind: :http_status, status: 404, body: "not found")

      assert error.kind === :http_status
      assert error.status === 404
      assert error.body === "not found"
      assert Exception.message(error) === "streaming query failed with HTTP status 404: not found"
    end

    test "builds a :transport error carrying the reason" do
      reason = %Mint.TransportError{reason: :econnrefused}
      error = StreamError.exception(kind: :transport, reason: reason)

      assert error.kind === :transport
      assert error.reason === reason

      assert Exception.message(error) ===
               "streaming query transport error: %Mint.TransportError{reason: :econnrefused}"
    end

    test "builds a :decode error carrying the reason" do
      error = StreamError.exception(kind: :decode, reason: :unexpected_byte)

      assert error.kind === :decode

      assert Exception.message(error) ===
               "failed to decode JSONL row in streaming response: :unexpected_byte"
    end

    test "defaults to :transport when kind is omitted" do
      error = StreamError.exception([])
      assert error.kind === :transport
    end

    test "inspects a non-binary http body" do
      error = StreamError.exception(kind: :http_status, status: 500, body: %{"e" => 1})

      assert Exception.message(error) ===
               ~s(streaming query failed with HTTP status 500: %{"e" => 1})
    end

    test "builds an :unsupported error carrying the reason" do
      error = StreamError.exception(kind: :unsupported, reason: :unsupported_operation)

      assert error.kind === :unsupported
      assert error.reason === :unsupported_operation

      assert Exception.message(error) ===
               "streaming query is not supported by this connection: :unsupported_operation"
    end

    test "is raisable and rescuable" do
      assert_raise StreamError, fn ->
        raise StreamError, kind: :no_database
      end
    end
  end

  describe "stream/1" do
    test "raises the configured error when enumerated, not when built" do
      # Building it raised nothing, or this line would not be reached.
      stream = StreamError.stream(kind: :http_status, status: 500, body: "boom")

      error = assert_raise StreamError, fn -> Enum.to_list(stream) end

      assert error.kind === :http_status
      assert error.status === 500
      assert error.body === "boom"
    end
  end
end
