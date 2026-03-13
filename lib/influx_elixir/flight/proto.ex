defmodule InfluxElixir.Flight.Proto do
  @moduledoc """
  Protobuf message definitions for the Apache Arrow Flight protocol.

  These definitions correspond to the `arrow.flight.protocol` protobuf schema
  used by InfluxDB v3's Arrow Flight SQL endpoint. Messages are defined using
  the `Protobuf` DSL (proto3 syntax) rather than generated from `.proto` files.

  ## Key Messages

    * `Ticket` — opaque bytes identifying a query result set
    * `FlightData` — a chunk of Arrow IPC data in a Flight stream
    * `FlightDescriptor` — describes how to locate a flight
    * `FlightInfo` — metadata about an available flight (schema, endpoints, counts)
    * `FlightEndpoint` — a `Ticket` + list of `Location`s where data is available
    * `Location` — a URI pointing to a Flight service
    * `HandshakeRequest` / `HandshakeResponse` — initial authentication exchange

  ## Service

    * `FlightService.Service` — gRPC service definition
    * `FlightService.Stub` — generated client stub (use for queries)
  """
end

defmodule InfluxElixir.Flight.Proto.Ticket do
  @moduledoc """
  An opaque bytes token identifying a result set.

  InfluxDB v3 expects the ticket to contain a JSON payload:

      %{"database" => "mydb", "sql_query" => "SELECT ...", "query_type" => "sql"}

  Encoded as UTF-8 JSON bytes in the `ticket` field.
  """

  use Protobuf, syntax: :proto3

  field(:ticket, 1, type: :bytes)
end

defmodule InfluxElixir.Flight.Proto.FlightDescriptor do
  @moduledoc """
  Describes how to locate or identify a Flight (a named dataset or query).

  The `type` field selects between a named dataset (`UNKNOWN = 0`, `PATH = 1`)
  or an opaque command blob (`CMD = 2`). InfluxDB uses `CMD` for SQL queries.
  """

  use Protobuf, syntax: :proto3

  field(:type, 1, type: :int32)
  field(:cmd, 2, type: :bytes)
  field(:path, 3, repeated: true, type: :string)
end

defmodule InfluxElixir.Flight.Proto.Location do
  @moduledoc """
  A URI identifying where a Flight service is available.

  Example: `"grpc+tls://us-east-1.influxdb.io:443"`
  """

  use Protobuf, syntax: :proto3

  field(:uri, 1, type: :string)
end

defmodule InfluxElixir.Flight.Proto.FlightEndpoint do
  @moduledoc """
  A `Ticket` paired with a list of `Location`s that can serve the data.

  Clients should call `DoGet` with the `ticket` at any of the listed locations.
  An empty `location` list means the originating server is the correct endpoint.
  """

  use Protobuf, syntax: :proto3

  field(:ticket, 1, type: InfluxElixir.Flight.Proto.Ticket)
  field(:location, 2, repeated: true, type: InfluxElixir.Flight.Proto.Location)
end

defmodule InfluxElixir.Flight.Proto.FlightInfo do
  @moduledoc """
  Metadata returned by `GetFlightInfo`, describing a result set.

  Contains the Arrow schema bytes, a list of endpoints from which to fetch data,
  and optional row/byte counts for planning purposes.
  """

  use Protobuf, syntax: :proto3

  field(:schema, 1, type: :bytes)
  field(:flight_descriptor, 2, type: InfluxElixir.Flight.Proto.FlightDescriptor)
  field(:endpoint, 3, repeated: true, type: InfluxElixir.Flight.Proto.FlightEndpoint)
  field(:total_records, 4, type: :int64)
  field(:total_bytes, 5, type: :int64)
end

defmodule InfluxElixir.Flight.Proto.FlightData do
  @moduledoc """
  A chunk of Arrow IPC data streamed from a `DoGet` call.

  The first message in a `DoGet` stream contains the Arrow schema in
  `data_header` with an empty `data_body`. Subsequent messages contain
  record batch headers in `data_header` and the corresponding column
  buffer data in `data_body`.

  ## Fields

    * `flight_descriptor` — present only in the first message of a `DoPut` stream
    * `data_header` — serialised Arrow IPC `Message` flatbuffer (schema or batch)
    * `app_metadata` — application-defined metadata bytes
    * `data_body` — raw column buffer bytes for record batches (field number 1000)
  """

  use Protobuf, syntax: :proto3

  field(:flight_descriptor, 1, type: InfluxElixir.Flight.Proto.FlightDescriptor)
  field(:data_header, 2, type: :bytes)
  field(:app_metadata, 3, type: :bytes)
  # data_body uses field number 1000 per the Arrow Flight spec
  field(:data_body, 1000, type: :bytes)
end

defmodule InfluxElixir.Flight.Proto.HandshakeRequest do
  @moduledoc """
  Initial client message in the `Handshake` RPC.

  Carries a `protocol_version` and an optional `payload` (e.g., bearer token bytes).
  """

  use Protobuf, syntax: :proto3

  field(:protocol_version, 1, type: :uint64)
  field(:payload, 2, type: :bytes)
end

defmodule InfluxElixir.Flight.Proto.HandshakeResponse do
  @moduledoc """
  Server response in the `Handshake` RPC.

  Carries the negotiated `protocol_version` and an optional `payload`
  (e.g., a session token returned by the server).
  """

  use Protobuf, syntax: :proto3

  field(:protocol_version, 1, type: :uint64)
  field(:payload, 2, type: :bytes)
end

defmodule InfluxElixir.Flight.Proto.FlightService.Service do
  @moduledoc """
  gRPC service definition for the Arrow Flight protocol.

  Only the RPCs required by the InfluxDB v3 Flight query path are defined here:

    * `DoGet` — streams `FlightData` for a given `Ticket`
    * `GetFlightInfo` — returns `FlightInfo` for a `FlightDescriptor`

  The full Flight spec also includes `Handshake`, `ListFlights`, `DoPut`,
  `DoAction`, `ListActions`, and `DoExchange`; these can be added as needed.
  """

  use GRPC.Service,
    name: "arrow.flight.protocol.FlightService",
    protoc_gen_elixir_version: "0.12.0"

  alias InfluxElixir.Flight.Proto.{
    FlightData,
    FlightDescriptor,
    FlightInfo,
    Ticket
  }

  rpc(:DoGet, Ticket, stream(FlightData))
  rpc(:GetFlightInfo, FlightDescriptor, FlightInfo)
end

defmodule InfluxElixir.Flight.Proto.FlightService.Stub do
  @moduledoc """
  Generated gRPC client stub for `FlightService`.

  ## Usage

      {:ok, channel} = GRPC.Stub.connect("my-influx.example.com:443",
        cred: GRPC.Credential.new(ssl: []))

      ticket = %InfluxElixir.Flight.Proto.Ticket{
        ticket: Jason.encode!(%{
          "database"   => "mydb",
          "sql_query"  => "SELECT * FROM cpu",
          "query_type" => "sql"
        })
      }

      {:ok, stream} = InfluxElixir.Flight.Proto.FlightService.Stub.do_get(channel, ticket)

      data = Enum.map(stream, fn {:ok, flight_data} -> flight_data end)
  """

  use GRPC.Stub, service: InfluxElixir.Flight.Proto.FlightService.Service
end
