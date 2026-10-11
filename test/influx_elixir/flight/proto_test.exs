defmodule InfluxElixir.Flight.ProtoTest do
  # The Flight messages against the wire bytes Arrow's `Flight.proto` gives them. A round
  # trip alone holds for any field numbering, so every message is pinned to its bytes: a tag
  # byte is `field_number <<< 3 ||| wire_type` (0 varint, 2 length-delimited).
  use ExUnit.Case, async: true

  alias InfluxElixir.Flight.Proto.{
    FlightData,
    FlightDescriptor,
    FlightEndpoint,
    FlightInfo,
    FlightService,
    HandshakeRequest,
    HandshakeResponse,
    Location,
    Ticket
  }

  # Encodes `message` to exactly `bytes`, and decodes `bytes` back to `message`.
  defp assert_wire(message, bytes) do
    assert IO.iodata_to_binary(Protobuf.encode(message)) === bytes
    assert Protobuf.decode(bytes, message.__struct__) === message
  end

  test "Ticket: the ticket is bytes field 1" do
    assert_wire(%Ticket{ticket: ~s({"database":"db"})}, <<0x0A, 17, ~s({"database":"db"})>>)
  end

  test "FlightData: descriptor 1, data_header 2, app_metadata 3, data_body 1000" do
    # field 1000, wire type 2 is the tag 8002, the varint <<0xC2, 0x3E>>
    assert_wire(
      %FlightData{
        flight_descriptor: %FlightDescriptor{type: 2},
        data_header: <<10, 20>>,
        app_metadata: "m",
        data_body: <<40, 50, 60>>
      },
      <<0x0A, 2, 0x08, 2, 0x12, 2, 10, 20, 0x1A, 1, "m", 0xC2, 0x3E, 3, 40, 50, 60>>
    )
  end

  test "FlightDescriptor: type 1 (a varint), cmd 2, path 3 repeated" do
    assert_wire(
      %FlightDescriptor{type: 2, cmd: "q", path: ["a", "b"]},
      <<0x08, 2, 0x12, 1, "q", 0x1A, 1, "a", 0x1A, 1, "b">>
    )
  end

  test "Location, FlightEndpoint and FlightInfo nest by their field numbers" do
    assert_wire(%Location{uri: "grpc://h:443"}, <<0x0A, 12, "grpc://h:443">>)

    endpoint = %FlightEndpoint{ticket: %Ticket{ticket: "t"}, location: [%Location{uri: "u"}]}
    endpoint_bytes = <<0x0A, 3, 0x0A, 1, "t", 0x12, 3, 0x0A, 1, "u">>
    assert_wire(endpoint, endpoint_bytes)

    # total_records 1000 is the varint <<0xE8, 0x07>>
    assert_wire(
      %FlightInfo{
        schema: <<1, 2>>,
        flight_descriptor: %FlightDescriptor{type: 2},
        endpoint: [endpoint],
        total_records: 1_000,
        total_bytes: 5
      },
      <<0x0A, 2, 1, 2, 0x12, 2, 0x08, 2, 0x1A, byte_size(endpoint_bytes)>> <>
        endpoint_bytes <> <<0x20, 0xE8, 0x07, 0x28, 5>>
    )
  end

  test "Handshake messages: protocol_version 1 (a varint), payload 2" do
    assert_wire(%HandshakeRequest{protocol_version: 1, payload: "p"}, <<0x08, 1, 0x12, 1, "p">>)
    assert_wire(%HandshakeResponse{protocol_version: 2, payload: "s"}, <<0x08, 2, 0x12, 1, "s">>)
  end

  test "the service is Arrow's FlightService: DoGet streams, GetFlightInfo is unary" do
    assert FlightService.Service.__meta__(:name) === "arrow.flight.protocol.FlightService"

    calls =
      for {name, request, reply, _opts} <- FlightService.Service.__rpc_calls__(),
          do: {name, request, reply}

    assert Enum.sort(calls) === [
             {:DoGet, {Ticket, false}, {FlightData, true}},
             {:GetFlightInfo, {FlightDescriptor, false}, {FlightInfo, false}}
           ]
  end
end
