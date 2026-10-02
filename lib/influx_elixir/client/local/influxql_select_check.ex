defmodule InfluxElixir.Client.Local.InfluxQLSelectCheck do
  @moduledoc """
  The checks the engine's parser makes on the select list and `FROM`, each
  reporting the position the engine reports (see
  `InfluxElixir.Client.Local.InfluxQLError`).
  """

  alias InfluxElixir.Client.Local.{InfluxQLError, InfluxQLReserved}

  @select_start ~r/^\s*SELECT(?![\w])\s*/i

  # An operator, what follows it up to the operand (signs and opening
  # parentheses) and the word the operand starts with.
  @operand ~r/([+\-*\/%&|^])\s*()(?:[+\-(]\s*)*([A-Za-z_]\w*)(?![\w])/

  # The select list and `FROM`, as the engine's parser reads them (verified):
  #
  #   * a select list that is empty or starts with a reserved word (after any
  #     signs) is "expected field" where the list starts
  #   * a later item that starts with a reserved word leaves the whole
  #     statement unparsed (position 0); a reserved word first in a function's
  #     argument fails from there, at position 0
  #   * a reserved word where the operand after a binary operator is wanted
  #     (`i + as`, `i + from FROM t`, `i + FROM t`) fails from the operand on
  #     (signs and parentheses before the word included), at position 0, after
  #     `+` or `-`; after another operator the statement is left unparsed
  #   * an alias after `AS` that is reserved is "invalid field alias", at the
  #     end of `AS`; a lone `DISTINCT` is "invalid DISTINCT expression", at
  #     `FROM`
  #   * `FROM` followed by nothing, by a reserved word or by a character that
  #     starts no identifier is "invalid FROM clause", where the name starts
  @spec check_select(binary(), binary()) :: :ok | {:error, term()}
  @doc false
  def check_select(whole, masked) do
    case Regex.run(@select_start, masked, return: :index) do
      [{0, items_at}] -> check_list(whole, masked, items_at)
      _no_select -> :ok
    end
  end

  @spec check_list(binary(), binary(), non_neg_integer()) :: :ok | {:error, term()}
  defp check_list(whole, masked, items_at) do
    rest = binary_part(masked, items_at, byte_size(masked) - items_at)

    if rest == "" or reserved_item?(rest) or reserved_item?(skip_signs(rest)) do
      {:error, {:engine, InfluxQLError.syntax_error_body(:field, items_at, whole)}}
    else
      check_from_keyword(whole, masked, items_at)
    end
  end

  @spec check_from_keyword(binary(), binary(), non_neg_integer()) :: :ok | {:error, term()}
  defp check_from_keyword(whole, masked, items_at) do
    case from_keyword(masked, items_at) do
      {:from, from_at, from_length} ->
        items = binary_part(masked, items_at, from_at - items_at)

        with :ok <- check_items(whole, items, items_at, from_at + 1),
             do: check_from(masked, from_at + from_length)

      {:operator, operator, operand_at} ->
        {:error, {:engine, operator_body(operator, operand_at, whole)}}

      :none ->
        rest = masked |> binary_part(items_at, byte_size(masked) - items_at) |> String.trim()
        body = reserved_operand(rest, items_at, whole)
        {:error, {:engine, body || InfluxQLError.syntax_error_body(:nom, 0, whole)}}
    end
  end

  @spec skip_signs(binary()) :: binary()
  defp skip_signs(text), do: Regex.replace(~r/^(?:[+\-]\s*)+/, text, "")

  # `DISTINCT` is read by the select list, not refused as a reserved word.
  @spec reserved_item?(binary()) :: boolean()
  defp reserved_item?(text) do
    case InfluxQLReserved.reserved_start(text) do
      {word, _size} -> String.downcase(word) != "distinct"
      nil -> false
    end
  end

  # The `FROM` that ends the select list: one that follows a binary operator
  # is the word the operand should have been, not the keyword.
  @spec from_keyword(binary(), non_neg_integer()) ::
          {:from, non_neg_integer(), non_neg_integer()}
          | {:operator, byte(), non_neg_integer()}
          | :none
  defp from_keyword(masked, items_at) do
    candidates =
      for [{at, length}] <- Regex.scan(~r/\sFROM(?![\w])\s*/i, masked, return: :index),
          at >= items_at,
          do: {at, length}

    Enum.find_value(candidates, :none, fn {at, length} ->
      before = binary_part(masked, items_at, at - items_at)

      case operator_before(before) do
        nil -> {:from, at, length}
        {operator, operand_at} -> {:operator, operator, operand_start(before, operand_at, at)}
      end
    end)
  end

  # Where the operand after an operator starts: the `FROM` itself when nothing
  # follows the operator in the text before it.
  @spec operand_start(binary(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp operand_start(before, operand_at, from_at) do
    if operand_at == byte_size(before),
      do: from_at + 1,
      else: from_at - byte_size(before) + operand_at
  end

  # A binary operator at the end of `text`, with where its operand starts.
  @spec operator_before(binary()) :: {byte(), non_neg_integer()} | nil
  defp operator_before(text) do
    with [_all, {at, 1}, {operand_at, 0}] <-
           Regex.run(~r/([+\-*\/%&|^])\s*()(?:[+\-(]\s*)*$/, text, return: :index),
         true <- binary_operator?(text, at) do
      {:binary.at(text, at), operand_at}
    else
      _no_operator -> nil
    end
  end

  # An operator is binary when an operand stands before it.
  @spec binary_operator?(binary(), non_neg_integer()) :: boolean()
  defp binary_operator?(text, at) do
    text |> binary_part(0, at) |> String.trim_trailing() |> String.match?(~r/[\w)"']$/)
  end

  @spec operator_body(byte(), non_neg_integer(), binary()) :: binary()
  defp operator_body(operator, operand_at, whole) when operator in [?+, ?-],
    do: InfluxQLError.syntax_error_body(:failure, operand_at, whole)

  defp operator_body(_operator, _operand_at, whole),
    do: InfluxQLError.syntax_error_body(:nom, 0, whole)

  @spec check_from(binary(), non_neg_integer()) :: :ok | {:error, term()}
  defp check_from(masked, from_end) do
    rest = binary_part(masked, from_end, byte_size(masked) - from_end)

    if rest == "" or InfluxQLReserved.reserved_start(rest) != nil or
         not (rest =~ ~r/^[A-Za-z_"\/(]/),
       do: {:error, {:engine, InfluxQLError.syntax_error_body(:from, from_end, masked)}},
       else: :ok
  end

  # The comma-separated pieces of a text, each with its offset in the statement.
  @spec comma_pieces(binary(), non_neg_integer()) :: [{binary(), non_neg_integer()}]
  @doc false
  def comma_pieces(text, base) do
    text
    |> String.split(",")
    |> Enum.map_reduce(base, &{{&1, &2}, &2 + byte_size(&1) + 1})
    |> elem(0)
  end

  @spec check_items(binary(), binary(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp check_items(whole, items, items_at, from_keyword_at) do
    pieces = comma_pieces(items, items_at)
    last = length(pieces) - 1

    pieces
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {{piece, at}, index} ->
      case check_item(whole, piece, at, index, index == last, from_keyword_at) do
        :ok -> nil
        error -> error
      end
    end)
  end

  @spec check_item(
          binary(),
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          non_neg_integer()
        ) ::
          :ok | {:error, term()}
  defp check_item(whole, piece, at, index, last?, from_keyword_at) do
    text = String.trim_leading(piece)
    start = at + byte_size(piece) - byte_size(text)
    text = String.trim_trailing(text)

    cond do
      String.downcase(text) == "distinct" and last? ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:distinct, from_keyword_at, whole)}}

      String.downcase(text) == "distinct" ->
        {:error, "unsupported InfluxQL (DISTINCT)"}

      index > 0 and (text == "" or InfluxQLReserved.reserved_start(text, plain: true) != nil) ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:nom, 0, whole)}}

      body = reserved_operand(text, start, whole) ->
        {:error, {:engine, body}}

      pos = reserved_alias(text, start) ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:alias, pos, whole)}}

      true ->
        :ok
    end
  end

  # The first place a reserved word stands where an operand is wanted: after
  # a binary operator, or first in a call's parentheses. The engine fails
  # there (see `check_select/2`).
  @spec reserved_operand(binary(), non_neg_integer(), binary()) :: binary() | nil
  defp reserved_operand(text, start, whole) do
    [operator_hit(text, start, whole), argument_hit(text, start, whole)]
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
    |> then(fn hit -> hit && elem(hit, 1) end)
  end

  @spec operator_hit(binary(), non_neg_integer(), binary()) :: {non_neg_integer(), binary()} | nil
  defp operator_hit(text, start, whole) do
    @operand
    |> Regex.scan(text, return: :index)
    |> Enum.find_value(fn [_all, {operator_at, 1}, {operand_at, 0}, {word_at, _length}] ->
      <<_skip::binary-size(word_at), word_and_rest::binary>> = text

      if binary_operator?(text, operator_at) and
           InfluxQLReserved.reserved_start(word_and_rest, plain: true) != nil do
        operator = :binary.at(text, operator_at)
        {start + operand_at, operator_body(operator, start + operand_at, whole)}
      end
    end)
  end

  @spec argument_hit(binary(), non_neg_integer(), binary()) :: {non_neg_integer(), binary()} | nil
  defp argument_hit(text, start, whole) do
    ~r/[A-Za-z_]\w*\s*\(\s*([A-Za-z_]\w*)/
    |> Regex.scan(text, return: :index)
    |> Enum.find_value(fn [_all, {from, _length}] ->
      <<_skip::binary-size(from), word_and_rest::binary>> = text

      if InfluxQLReserved.reserved_start(word_and_rest) != nil,
        do: {start + from, InfluxQLError.syntax_error_body(:failure, start + from, whole)}
    end)
  end

  # The end of `AS` when the alias after it is reserved.
  @spec reserved_alias(binary(), non_neg_integer()) :: non_neg_integer() | nil
  defp reserved_alias(text, start) do
    case Regex.run(~r/\s(AS)(?![\w])\s*([A-Za-z_]\w*)/i, text, return: :index) do
      [_all, {as_at, as_length}, {alias_at, _length}] ->
        <<_skip::binary-size(alias_at), alias_and_rest::binary>> = text
        if InfluxQLReserved.reserved_start(alias_and_rest), do: start + as_at + as_length

      nil ->
        last_as(text, start)
    end
  end

  # An `AS` last in the list: the word after it was cut off as `FROM`.
  @spec last_as(binary(), non_neg_integer()) :: non_neg_integer() | nil
  defp last_as(text, start) do
    case Regex.run(~r/\s(AS)(?![\w])\s*$/i, text, return: :index) do
      [_all, {as_at, as_length}] -> start + as_at + as_length
      nil -> nil
    end
  end
end
