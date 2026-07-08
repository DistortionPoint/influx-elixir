defmodule InfluxElixir.StreamErrorTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.StreamError

  describe "exception/1" do
    test "builds a :no_database error with a helpful message" do
      error = StreamError.exception(kind: :no_database)

      assert error.kind == :no_database
      assert error.message =~ "no database specified"
    end

    test "builds an :http_status error carrying status and body" do
      error = StreamError.exception(kind: :http_status, status: 404, body: "not found")

      assert error.kind == :http_status
      assert error.status == 404
      assert error.body == "not found"
      assert error.message =~ "404"
      assert error.message =~ "not found"
    end

    test "builds a :transport error carrying the reason" do
      reason = %Mint.TransportError{reason: :econnrefused}
      error = StreamError.exception(kind: :transport, reason: reason)

      assert error.kind == :transport
      assert error.reason == reason
      assert error.message =~ "transport error"
    end

    test "builds a :decode error carrying the reason" do
      error = StreamError.exception(kind: :decode, reason: :unexpected_byte)

      assert error.kind == :decode
      assert error.message =~ "decode"
    end

    test "defaults to :transport when kind is omitted" do
      error = StreamError.exception([])
      assert error.kind == :transport
    end

    test "inspects a non-binary http body" do
      error = StreamError.exception(kind: :http_status, status: 500, body: %{"e" => 1})
      assert error.message =~ ~s(%{"e" => 1})
    end

    test "builds an :unsupported error carrying the reason" do
      error = StreamError.exception(kind: :unsupported, reason: :unsupported_operation)

      assert error.kind == :unsupported
      assert error.reason == :unsupported_operation
      assert error.message =~ "not supported"
    end

    test "is raisable and rescuable" do
      assert_raise StreamError, fn ->
        raise StreamError, kind: :no_database
      end
    end
  end

  describe "stream/1" do
    test "returns an enumerable that does not raise on construction" do
      stream = StreamError.stream(kind: :http_status, status: 500, body: "boom")
      assert Enumerable.impl_for(stream)
    end

    test "raises the configured error when enumerated" do
      stream = StreamError.stream(kind: :http_status, status: 500, body: "boom")

      error =
        try do
          Enum.to_list(stream)
          nil
        rescue
          e in StreamError -> e
        end

      assert error.kind == :http_status
      assert error.status == 500
      assert error.body == "boom"
    end
  end
end
