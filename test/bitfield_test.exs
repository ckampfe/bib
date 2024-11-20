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
end
