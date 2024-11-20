defmodule Bib.Bitfield do
  # from https://stackoverflow.com/questions/49555619/how-to-flip-a-single-specific-bit-in-an-erlang-bitstring
  def set_bit(bitstring, index) when is_bitstring(bitstring) do
    <<a::bits-size(index), _::1, b::bits>> = bitstring
    <<a::bits, 1::1, b::bits>>
  end

  # from https://stackoverflow.com/questions/49555619/how-to-flip-a-single-specific-bit-in-an-erlang-bitstring
  # defp unset_bit(bs, index) when is_bitstring(bs) do
  #   <<a::bits-size(index), _::1, b::bits>> = bs
  #   <<a::bits, 0::1, b::bits>>
  # end

  def diff_bitstrings(left, right) when bit_size(left) == bit_size(right) do
    do_diff_bitstrings(left, right, <<>>)
  end

  defp do_diff_bitstrings(<<>>, <<>>, acc) do
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
  return the indexes in the bitset for the bits set to 1
  """
  def population_indexes(<<bitset::bits>>) do
    {indexes, _} =
      for <<bit::1 <- bitset>>, reduce: {[], 0} do
        {indexes, i} ->
          if bit == 1 do
            {[i | indexes], i + 1}
          else
            {indexes, i + 1}
          end
      end

    indexes
  end
end
