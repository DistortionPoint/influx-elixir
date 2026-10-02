defmodule InfluxElixir.Client.Local.InfluxQLShow do
  @moduledoc """
  `SHOW TAG VALUES`, and whether a `WHERE` names `time`.
  """

  alias InfluxElixir.Client.Local.{InfluxQL, InfluxQLCheck, InfluxQLParser, InfluxQLTokens}

  @show_tag_values ~r/^\s*SHOW\s+TAG\s+VALUES(?:\s+FROM\s+(?<from>"(?:[^"\\]|\\.)+"|[\w\-]+))?\s+WITH\s+KEY\s*(?<op>=~|!~|!=|=|IN\b)\s*(?<spec>.+?)(?:\s+WHERE\s+(?<where>.+?))?\s*;?\s*$/is

  @doc """
  Parses `SHOW TAG VALUES [FROM m] WITH KEY = k | != k | =~ /re/ | !~ /re/ |
  IN (k, ...) [WHERE ...]`, or `nil` when the statement is not one.
  `LIMIT` and `OFFSET` are refused by name: the engine applies them per
  measurement in an order the double does not reproduce.
  """
  @spec parse_show_tag_values(binary()) ::
          nil
          | {:ok,
             %{measurement: binary() | nil, keys: InfluxQL.key_filter(), where: binary() | nil}}
          | {:error, binary() | {:engine, binary()}}
  def parse_show_tag_values(statement) do
    with %{} = captures <- Regex.named_captures(@show_tag_values, statement),
         :ok <- check_where(statement, captures["where"]) do
      if Regex.match?(~r/\b(?:LIMIT|OFFSET)\b/i, captures["where"] <> " " <> captures["spec"]) do
        {:error, "unsupported InfluxQL (SHOW TAG VALUES with LIMIT/OFFSET)"}
      else
        with {:ok, keys} <-
               key_filter(String.upcase(captures["op"]), String.trim(captures["spec"])) do
          {:ok,
           %{
             measurement:
               captures["from"]
               |> InfluxQLParser.blank_to_nil()
               |> then(&(&1 && InfluxQLParser.unquote_ident(&1))),
             keys: keys,
             where: InfluxQLParser.blank_to_nil(captures["where"])
           }}
        end
      end
    end
  end

  # The `WHERE` is read as that of a `SELECT` is, with the positions of the
  # statement as sent.
  @spec check_where(binary(), binary()) :: :ok | {:error, {:engine, binary()}}
  defp check_where(_statement, ""), do: :ok

  defp check_where(statement, where) do
    masked = InfluxQLParser.mask_literals(statement)
    InfluxQLCheck.check_where(statement, 0, masked, InfluxQLParser.blank_to_nil(where))
  end

  @spec key_filter(binary(), binary()) :: {:ok, InfluxQL.key_filter()} | {:error, binary()}
  defp key_filter(op, "/" <> _rest = spec) when op in ["=~", "!~"] do
    case Regex.compile(spec |> String.trim("/") |> String.replace("\\/", "/"), "u") do
      {:ok, regex} -> {:ok, {:regex, regex, op == "=~"}}
      {:error, _reason} -> {:error, "unsupported InfluxQL (invalid regex #{spec})"}
    end
  end

  defp key_filter("IN", "(" <> _rest = spec) do
    keys = spec |> String.trim_leading("(") |> String.trim_trailing(")") |> String.split(",")
    {:ok, {:in, Enum.map(keys, &(&1 |> String.trim() |> InfluxQLParser.unquote_ident()))}}
  end

  defp key_filter("=", spec), do: {:ok, {:eq, InfluxQLParser.unquote_ident(spec)}}
  defp key_filter("!=", spec), do: {:ok, {:ne, InfluxQLParser.unquote_ident(spec)}}
  defp key_filter(op, spec), do: {:error, "unsupported InfluxQL (WITH KEY #{op} #{spec})"}

  @doc "Whether a tag key is one a `key_filter/0` lists."
  @spec key_listed?(binary(), InfluxQL.key_filter()) :: boolean()
  def key_listed?(key, {:eq, name}), do: key == name
  def key_listed?(key, {:ne, name}), do: key != name
  def key_listed?(key, {:in, names}), do: key in names
  def key_listed?(key, {:regex, regex, match?}), do: Regex.match?(regex, key) == match?

  @doc "Whether a `WHERE` names `time`: then it, not the default window, bounds the rows."
  @spec mentions_time?(binary() | nil) :: boolean()
  def mentions_time?(nil), do: false

  def mentions_time?(where) do
    case InfluxQLTokens.tokenize(where, []) do
      {:ok, tokens} -> Enum.any?(tokens, &InfluxQLTokens.time?/1)
      _not_or_refusal -> false
    end
  end
end
