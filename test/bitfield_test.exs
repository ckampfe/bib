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
end
