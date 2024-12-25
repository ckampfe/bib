defmodule BitfieldTest do
  use ExUnit.Case
  alias Bib.Bitfield

  test "set_bit/2" do
    assert Bitfield.set_bit(<<0, 0, 0, 0>>, 0) == <<128, 0, 0, 0>>

    assert Bitfield.set_bit(<<0, 0, 0, 0>>, 7) == <<1, 0, 0, 0>>

    assert Bitfield.set_bit(<<0, 0, 0, 0>>, 8) == <<0, 128, 0, 0>>

    assert <<0, 0, 0, 0>>
           |> Bitfield.set_bit(8)
           |> Bitfield.set_bit(9) == <<0, 192, 0, 0>>
  end

  test "set_indexes/1" do
    assert Bitfield.set_indexes(<<>>) == []
    assert Bitfield.set_indexes(<<1::1>>) == [0]
    assert Bitfield.set_indexes(<<0::1>>) == []
    assert Bitfield.set_indexes(<<0::1, 1::1, 1::1, 0::1, 0::1, 1::1>>) == [5, 2, 1]
  end

  test "unset_indexes/1" do
    assert Bitfield.unset_indexes(<<>>) == []
    assert Bitfield.unset_indexes(<<1::1>>) == []
    assert Bitfield.unset_indexes(<<0::1>>) == [0]
    assert Bitfield.unset_indexes(<<0::1, 1::1, 1::1, 0::1, 0::1, 1::1>>) == [4, 3, 0]
  end

  test "diff_bitstrings/2" do
    assert Bitfield.diff_bitstrings(<<0, 0, 0, 1>>, <<1, 0, 0, 0>>) == <<0, 0, 0, 1>>
  end

  test "pad_to_binary/1" do
    assert Bitfield.pad_to_binary(<<0::1>>) == <<0>>
    assert Bitfield.pad_to_binary(<<0::9>>) == <<0, 0>>
    assert Bitfield.pad_to_binary(<<0::23>>) == <<0, 0, 0>>
  end

  test "counts/1" do
    assert Bitfield.counts(<<>>) == %{have: 0, want: 0}
    assert Bitfield.counts(<<0::1>>) == %{have: 0, want: 1}
    assert Bitfield.counts(<<1::1>>) == %{have: 1, want: 0}
    assert Bitfield.counts(<<1::1, 0::1>>) == %{have: 1, want: 1}
    assert Bitfield.counts(<<1::1, 0::1, 1::1>>) == %{have: 2, want: 1}
    assert Bitfield.counts(<<1::1, 0::1, 1::1, 1::1, 0::1>>) == %{have: 3, want: 2}
  end
end
