defmodule Bib.Bitfield do
  # from https://stackoverflow.com/questions/49555619/how-to-flip-a-single-specific-bit-in-an-erlang-bitstring

  def new_padded(n) when is_integer(n) and n > 0 do
    pad_to_binary(<<0::size(n)>>)
  end

  @spec set_bit(nonempty_bitstring(), non_neg_integer()) :: nonempty_bitstring()
  def set_bit(bitstring, index) when is_bitstring(bitstring) do
    <<a::bits-size(index), _::1, b::bits>> = bitstring
    <<a::bits, 1::1, b::bits>>
  end

  def pad_to_binary(<<bitstring::bits>>) do
    size = :erlang.bit_size(bitstring)

    remainder_of_8 = rem(size, 8)

    if remainder_of_8 == 0 do
      bitstring
    else
      zeros_to_pad = 8 - remainder_of_8
      <<bitstring::bits, 0::size(zeros_to_pad)>>
    end
  end

  # from https://stackoverflow.com/questions/49555619/how-to-flip-a-single-specific-bit-in-an-erlang-bitstring
  # defp unset_bit(bs, index) when is_bitstring(bs) do
  #   <<a::bits-size(index), _::1, b::bits>> = bs
  #   <<a::bits, 0::1, b::bits>>
  # end

  @doc """
  we use this to gauge interest.
  if right has something left doesn't have,
  left is interested in right.

  there's probably a faster way to do this that isn't linear time but oh well
  """
  def right_has_some_left_doesnt_have(<<>>, _right) do
    false
  end

  def right_has_some_left_doesnt_have(<<l::1, left::bits>>, <<r::1, right::bits>>) do
    if l == 0 && r == 1 do
      true
    else
      right_has_some_left_doesnt_have(left, right)
    end
  end

  def random_wanted_piece(peer_bitstring, my_bitstring) do
    diff_bitstrings(peer_bitstring, my_bitstring)
    |> set_indexes()
    |> then(fn
      [] ->
        nil

      indexes ->
        Enum.random(indexes)
    end)
  end

  def diff_bitstrings(left, right) do
    do_diff_bitstrings(left, right, <<>>)
  end

  defp do_diff_bitstrings(<<>>, _, acc) do
    acc
  end

  defp do_diff_bitstrings(_, <<>>, acc) do
    acc
  end

  defp do_diff_bitstrings(<<a::1, left_rest::bits>>, <<b::1, right_rest::bits>>, <<acc::bits>>) do
    # <<0, 0, 0, 1>> - <<1, 0, 0, 0>>
    # should be: <<0, 0, 0, 1>>
    diff =
      if a == 1 do
        a - b
      else
        0
      end

    do_diff_bitstrings(left_rest, right_rest, <<acc::bits, diff::1>>)
  end

  @doc """
  return a list of indexes where bits are set to 1
  """
  def set_indexes(<<bitstring::bits>>) do
    do_set_indexes(bitstring, 0, [])
  end

  defp do_set_indexes(<<>>, _i, acc), do: acc

  defp do_set_indexes(<<0::1, rest::bits>>, i, acc) do
    do_set_indexes(rest, i + 1, acc)
  end

  defp do_set_indexes(<<1::1, rest::bits>>, i, acc) do
    do_set_indexes(rest, i + 1, [i | acc])
  end

  @doc """
  return a list of indexes where bits are set to 0
  """
  def unset_indexes(<<bitstring::bits>>) do
    do_unset_indexes(bitstring, 0, [])
  end

  defp do_unset_indexes(<<>>, _i, acc), do: acc

  defp do_unset_indexes(<<0::1, rest::bits>>, i, acc) do
    do_unset_indexes(rest, i + 1, [i | acc])
  end

  defp do_unset_indexes(<<1::1, rest::bits>>, i, acc) do
    do_unset_indexes(rest, i + 1, acc)
  end

  @spec counts(bitstring()) :: %{have: integer(), want: integer()}
  def counts(bitset) do
    for <<bit::1 <- bitset>>, reduce: %{have: 0, want: 0} do
      acc ->
        if bit == 1 do
          Map.update!(acc, :have, fn have -> have + 1 end)
        else
          Map.update!(acc, :want, fn have -> have + 1 end)
        end
    end
  end
end
