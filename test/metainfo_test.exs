defmodule MetaInfoTest do
  use ExUnit.Case
  alias Bib.MetaInfo

  test "metainfo" do
    file = File.read!("The-Fanimatrix-(DivX-5.1-HQ).avi.torrent")
    {:ok, m, _} = Bib.Bencode.decode(file)

    pieces = m |> get_in(["info", "pieces"])

    mi = MetaInfo.new(m)
    assert MetaInfo.announce(mi) == "http://kaos.gen.nz:6969/announce"
    assert MetaInfo.length(mi) == 135_046_574
    assert MetaInfo.name(mi) == "The-Fanimatrix-(DivX-5.1-HQ).avi"
    assert MetaInfo.piece_length(mi) == 262_144
    assert MetaInfo.pieces_raw(mi) == pieces

    assert Enum.all?(MetaInfo.pieces(mi), fn piece ->
             byte_size(piece) == 20
           end)
  end
end
