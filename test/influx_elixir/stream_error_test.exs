defmodule InfluxElixir.StreamErrorTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.StreamError

  describe "exception/1" do
    test "builds a :no_database error with a helpful message" do
      assert StreamError.exception(kind: :no_database) === %StreamError{
               kind: :no_database,
               message:
                 "no database specified for streaming query: pass `database:` in opts " <>
                   "or set `:database` on the connection"
             }
    end

    test "builds an :invalid_request error carrying the reason" do
      reason = {:invalid_param, "p", :unsupported_type}

      assert StreamError.exception(kind: :invalid_request, reason: reason) === %StreamError{
               kind: :invalid_request,
               reason: reason,
               message:
                 ~s|streaming query request is invalid: {:invalid_param, "p", :unsupported_type}|
             }
    end

    test "builds an :http_status error carrying status and body" do
      assert StreamError.exception(kind: :http_status, status: 404, body: "not found") ===
               %StreamError{
                 kind: :http_status,
                 status: 404,
                 body: "not found",
                 message: "streaming query failed with HTTP status 404: not found"
               }
    end

    test "builds a :transport error carrying the reason" do
      reason = %Mint.TransportError{reason: :econnrefused}

      assert StreamError.exception(kind: :transport, reason: reason) === %StreamError{
               kind: :transport,
               reason: reason,
               message:
                 "streaming query transport error: %Mint.TransportError{reason: :econnrefused}"
             }
    end

    test "builds a :decode error carrying the reason" do
      assert StreamError.exception(kind: :decode, reason: :unexpected_byte) === %StreamError{
               kind: :decode,
               reason: :unexpected_byte,
               message: "failed to decode JSONL row in streaming response: :unexpected_byte"
             }
    end

    test "defaults to a :transport error with no status, body or reason" do
      assert StreamError.exception([]) === %StreamError{
               kind: :transport,
               message: "streaming query transport error: nil"
             }
    end

    test "inspects a non-binary http body" do
      error = StreamError.exception(kind: :http_status, status: 500, body: %{"e" => 1})

      assert Exception.message(error) ===
               ~s(streaming query failed with HTTP status 500: %{"e" => 1})
    end

    test "builds an :unsupported error carrying the reason" do
      assert StreamError.exception(kind: :unsupported, reason: :unsupported_operation) ===
               %StreamError{
                 kind: :unsupported,
                 reason: :unsupported_operation,
                 message:
                   "streaming query is not supported by this connection: :unsupported_operation"
               }
    end

    test "raise builds the error from its options" do
      error = assert_raise StreamError, fn -> raise StreamError, kind: :no_database end

      assert error === StreamError.exception(kind: :no_database)
    end
  end

  describe "stream/1" do
    test "raises the configured error when enumerated, not when built" do
      # Building it raised nothing, or this line would not be reached.
      stream = StreamError.stream(kind: :http_status, status: 500, body: "boom")

      assert assert_raise(StreamError, fn -> Enum.to_list(stream) end) ===
               StreamError.exception(kind: :http_status, status: 500, body: "boom")
    end
  end
end
