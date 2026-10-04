defmodule InfluxElixir.Client.Local.SQLDmlName do
  @moduledoc false
  # How the engine prints the names of an `INSERT` or an `UPDATE` and words its schema error for
  # a field the table lacks (verified against InfluxDB 3 Core):
  #
  #   * a name is printed bare when it is lower case letters, digits and `_` (not starting with a
  #     digit), else in double quotes with a quote inside doubled
  #   * `No field named <name>. Valid fields are <field>, ...` lists the fields qualified by the
  #     relation the statement names the table by (none for an `INSERT`)
  #   * the first listed field that is within half its length in edits of the name's last part
  #     is the suggestion instead: `No field named <name>. Did you mean '<field>'?`
  #   * a qualified name that only differs from a field by case says so
  #     (`Column names are case sensitive. You can use double quotes ...`)

  @doc "A name as the engine prints it."
  @spec quote_ident(binary()) :: binary()
  def quote_ident(name) do
    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name), do: name, else: quote_always(name)
  end

  @doc "A name in double quotes."
  @spec quote_always(binary()) :: binary()
  def quote_always(name), do: ~s|"| <> String.replace(name, ~s|"|, ~s|""|) <> ~s|"|

  @doc "A name written in a statement (its text and whether it was quoted), as printed."
  @spec quote_name({binary(), boolean()} | binary()) :: binary()
  def quote_name({text, _quoted}), do: quote_ident(text)
  def quote_name(text), do: quote_ident(text)

  @doc """
  The engine's schema error for `printed`, a name written with `name` as its last part. `qualifier`
  is the relation the fields are listed through (`nil` for none), `columns` the table's.
  """
  @spec no_field(binary(), binary(), binary() | nil, [binary()]) :: map()
  def no_field(printed, name, qualifier, columns) do
    fields = Enum.map(columns, &field(qualifier, &1))
    folded? = qualifier != nil and String.contains?(printed, ".") and folded?(printed, fields)

    %{
      status: 500,
      body: "Schema error: No field named #{printed}." <> detail(printed, name, fields, folded?)
    }
  end

  @spec detail(binary(), binary(), [binary()], boolean()) :: binary()
  defp detail(printed, name, fields, folded?) do
    valid = Enum.join(fields, ", ")

    hint =
      if folded? do
        " Column names are case sensitive. You can use double quotes to refer to the " <>
          ~s|"#{printed}" column or set the datafusion.sql_parser.enable_ident_normalization configuration.|
      else
        ""
      end

    case Enum.find(fields, &close?(name, &1)) do
      nil -> hint <> " Valid fields are #{valid}."
      field -> hint <> " Did you mean '#{field}'?."
    end
  end

  @spec field(binary() | nil, binary()) :: binary()
  defp field(nil, column), do: column
  defp field(qualifier, column), do: qualifier <> "." <> quote_ident(column)

  # Whether the name written, folded to lower case with its quotes taken off, is a listed field.
  @spec folded?(binary(), [binary()]) :: boolean()
  defp folded?(printed, fields) do
    flat = printed |> String.replace(~s|"|, "") |> String.downcase()
    Enum.any?(fields, &(&1 |> String.replace(~s|"|, "") |> String.downcase() == flat))
  end

  # Whether two names are within half the longer one's length of each other in edits.
  @spec close?(binary(), binary()) :: boolean()
  defp close?(left, right) do
    longest = max(String.length(left), String.length(right))
    longest > 0 and edit_distance(left, right) * 2 <= longest
  end

  @spec edit_distance(binary(), binary()) :: non_neg_integer()
  defp edit_distance(left, right) do
    initial = Enum.to_list(0..String.length(right))

    left
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.reduce(initial, fn {a, row}, previous ->
      right
      |> String.graphemes()
      |> Enum.zip(Enum.zip(previous, tl(previous)))
      |> Enum.reduce([row], fn {b, {diagonal, above}}, [left_cell | _older] = acc ->
        cost = if a == b, do: 0, else: 1
        [min(min(above + 1, left_cell + 1), diagonal + cost) | acc]
      end)
      |> Enum.reverse()
    end)
    |> List.last()
  end
end
