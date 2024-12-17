defmodule BencodeTest do
  use ExUnit.Case
  alias Bib.Bencode

  test "decodes" do
    file = File.read!("The-Fanimatrix-(DivX-5.1-HQ).avi.torrent")
    {:ok, m, _} = Bencode.decode(file)
    keys = Map.keys(m)
    assert "announce" in keys
    assert "info" in keys
    info = Map.fetch!(m, "info")
    info_keys = Map.keys(info)
    assert "length" in info_keys
    assert "name" in info_keys
    assert "piece length" in info_keys
    assert "pieces" in info_keys
  end

  test "encodes" do
    file = File.read!("The-Fanimatrix-(DivX-5.1-HQ).avi.torrent")
    {:ok, m, _} = Bencode.decode(file)

    {:ok, roundtripped, _} =
      m
      |> Bencode.encode()
      |> :erlang.iolist_to_binary()
      |> Bencode.decode()

    assert m == roundtripped
  end

  test "decode/1 errors on bad input" do
    # dict with key but not value
    assert {:error, "expecting to parse string length, got 'e'", 14} ==
             Bencode.decode("d10:abcdefghije")

    # dict without 'e' end
    assert {:error, "expecting to parse dict end 'e' character, got end of input", 19} ==
             Bencode.decode("d10:abcdefghij3:abc")

    # integer with no digits
    assert {:error, "expecting to parse integer digits, got 'x'", 1} == Bencode.decode("ixe")

    # integer without 'e' end
    assert {:error, "expecting to parse integer end 'e' character, got ''", 3} ==
             Bencode.decode("i42")

    # list without 'e' end
    assert {:error, "expecting to parse list end 'e' character, got end of input", 14} ==
             Bencode.decode("l10:abcdefghij")

    # string with no separator
    assert {:error, "expecting to parse string separator ':', got ''", 2} ==
             Bencode.decode("14")

    # string with no string
    assert {:error, "expecting to parse string body with length 14, input ended early", 3} ==
             Bencode.decode("14:abc")
  end
end
