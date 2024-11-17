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
end
