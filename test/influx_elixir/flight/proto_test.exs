defmodule InfluxElixir.Flight.ProtoTest do
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

  describe "Ticket" do
    test "encodes and decodes ticket bytes round-trip" do
      payload = ~s({"database":"mydb","sql_query":"SELECT 1","query_type":"sql"})
      ticket = %Ticket{ticket: payload}
      encoded = Protobuf.encode(ticket)
      assert is_binary(encoded)
      decoded = Protobuf.decode(encoded, Ticket)
      assert decoded.ticket == payload
    end

    test "encodes empty ticket" do
      ticket = %Ticket{ticket: ""}
      encoded = Protobuf.encode(ticket)
      decoded = Protobuf.decode(encoded, Ticket)
      assert decoded.ticket == ""
    end

    test "struct defaults to empty bytes" do
      assert %Ticket{}.ticket == ""
    end
  end

  describe "FlightDescriptor" do
    test "encodes and decodes with type and cmd" do
      desc = %FlightDescriptor{type: 2, cmd: "SELECT * FROM cpu"}
      encoded = Protobuf.encode(desc)
      decoded = Protobuf.decode(encoded, FlightDescriptor)
      assert decoded.type == 2
      assert decoded.cmd == "SELECT * FROM cpu"
    end

    test "encodes and decodes with path" do
      desc = %FlightDescriptor{type: 1, path: ["bucket", "table"]}
      encoded = Protobuf.encode(desc)
      decoded = Protobuf.decode(encoded, FlightDescriptor)
      assert decoded.path == ["bucket", "table"]
    end

    test "defaults to empty values" do
      desc = %FlightDescriptor{}
      assert desc.type == 0
      assert desc.cmd == ""
      assert desc.path == []
    end
  end

  describe "Location" do
    test "encodes and decodes URI" do
      loc = %Location{uri: "grpc+tls://influxdb.example.com:443"}
      encoded = Protobuf.encode(loc)
      decoded = Protobuf.decode(encoded, Location)
      assert decoded.uri == "grpc+tls://influxdb.example.com:443"
    end

    test "defaults to empty string" do
      assert %Location{}.uri == ""
    end
  end

  describe "FlightEndpoint" do
    test "encodes and decodes ticket and locations" do
      endpoint = %FlightEndpoint{
        ticket: %Ticket{ticket: "tok"},
        location: [%Location{uri: "grpc://host:443"}]
      }

      encoded = Protobuf.encode(endpoint)
      decoded = Protobuf.decode(encoded, FlightEndpoint)
      assert decoded.ticket.ticket == "tok"
      assert length(decoded.location) == 1
      assert hd(decoded.location).uri == "grpc://host:443"
    end

    test "defaults to nil ticket and empty locations" do
      ep = %FlightEndpoint{}
      assert ep.ticket == nil
      assert ep.location == []
    end
  end

  describe "FlightInfo" do
    test "encodes and decodes all fields" do
      info = %FlightInfo{
        schema: <<1, 2, 3>>,
        flight_descriptor: %FlightDescriptor{type: 2, cmd: "q"},
        endpoint: [
          %FlightEndpoint{ticket: %Ticket{ticket: "t"}}
        ],
        total_records: 1_000,
        total_bytes: 512_000
      }

      encoded = Protobuf.encode(info)
      decoded = Protobuf.decode(encoded, FlightInfo)
      assert decoded.schema == <<1, 2, 3>>
      assert decoded.flight_descriptor.cmd == "q"
      assert decoded.total_records == 1_000
      assert decoded.total_bytes == 512_000
      assert length(decoded.endpoint) == 1
    end

    test "defaults correctly" do
      info = %FlightInfo{}
      assert info.schema == ""
      assert info.total_records == 0
      assert info.total_bytes == 0
    end
  end

  describe "FlightData" do
    test "encodes and decodes all fields" do
      fd = %FlightData{
        flight_descriptor: %FlightDescriptor{type: 0},
        data_header: <<10, 20, 30>>,
        app_metadata: "meta",
        data_body: <<40, 50, 60>>
      }

      encoded = Protobuf.encode(fd)
      decoded = Protobuf.decode(encoded, FlightData)
      assert decoded.data_header == <<10, 20, 30>>
      assert decoded.app_metadata == "meta"
      assert decoded.data_body == <<40, 50, 60>>
    end

    test "data_body field number is 1000 (high field number survives round-trip)" do
      fd = %FlightData{data_body: "body_content"}
      encoded = Protobuf.encode(fd)
      decoded = Protobuf.decode(encoded, FlightData)
      assert decoded.data_body == "body_content"
    end

    test "defaults to empty binaries" do
      fd = %FlightData{}
      assert fd.data_header == ""
      assert fd.app_metadata == ""
      assert fd.data_body == ""
    end
  end

  describe "HandshakeRequest" do
    test "encodes and decodes protocol_version and payload" do
      req = %HandshakeRequest{protocol_version: 1, payload: "bearer-token"}
      encoded = Protobuf.encode(req)
      decoded = Protobuf.decode(encoded, HandshakeRequest)
      assert decoded.protocol_version == 1
      assert decoded.payload == "bearer-token"
    end

    test "defaults to zero version and empty payload" do
      req = %HandshakeRequest{}
      assert req.protocol_version == 0
      assert req.payload == ""
    end
  end

  describe "HandshakeResponse" do
    test "encodes and decodes protocol_version and payload" do
      resp = %HandshakeResponse{protocol_version: 2, payload: "session-token"}
      encoded = Protobuf.encode(resp)
      decoded = Protobuf.decode(encoded, HandshakeResponse)
      assert decoded.protocol_version == 2
      assert decoded.payload == "session-token"
    end
  end

  describe "FlightService.Service" do
    test "has the correct gRPC service name" do
      assert FlightService.Service.__meta__(:name) ==
               "arrow.flight.protocol.FlightService"
    end

    test "defines DoGet and GetFlightInfo RPC calls" do
      rpc_names =
        FlightService.Service.__rpc_calls__()
        |> Enum.map(fn {name, _req, _resp, _opts} -> name end)

      assert :DoGet in rpc_names
      assert :GetFlightInfo in rpc_names
    end

    test "DoGet is a server-streaming call" do
      rpc_call =
        FlightService.Service.__rpc_calls__()
        |> Enum.find(fn {name, _req, _resp, _opts} -> name == :DoGet end)

      {_name, {_req, req_stream?}, {_resp, resp_stream?}, _opts} = rpc_call
      assert req_stream? == false
      assert resp_stream? == true
    end

    test "GetFlightInfo is a unary call" do
      rpc_call =
        FlightService.Service.__rpc_calls__()
        |> Enum.find(fn {name, _req, _resp, _opts} -> name == :GetFlightInfo end)

      {_name, {_req, req_stream?}, {_resp, resp_stream?}, _opts} = rpc_call
      assert req_stream? == false
      assert resp_stream? == false
    end
  end

  describe "FlightService.Stub" do
    test "is defined as a module" do
      assert Code.ensure_loaded?(FlightService.Stub)
    end

    test "has do_get function generated" do
      Code.ensure_loaded!(FlightService.Stub)
      assert function_exported?(FlightService.Stub, :do_get, 3)
    end

    test "has get_flight_info function generated" do
      Code.ensure_loaded!(FlightService.Stub)
      assert function_exported?(FlightService.Stub, :get_flight_info, 3)
    end
  end
end
