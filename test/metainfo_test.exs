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

  test "blocks_for_piece/3" do
    file = File.read!("The-Fanimatrix-(DivX-5.1-HQ).avi.torrent")
    {:ok, m, _} = Bib.Bencode.decode(file)
    mi = MetaInfo.new(m)

    assert MetaInfo.blocks_for_piece(mi, 0, 2 ** 14) ==
             [
               {0, 16384},
               {16384, 16384},
               {32768, 16384},
               {49152, 16384},
               {65536, 16384},
               {81920, 16384},
               {98304, 16384},
               {114_688, 16384},
               {131_072, 16384},
               {147_456, 16384},
               {163_840, 16384},
               {180_224, 16384},
               {196_608, 16384},
               {212_992, 16384},
               {229_376, 16384},
               {245_760, 16384}
             ]

    file = File.read!("a8dmfmt66t211.png.torrent")
    {:ok, m, _} = Bib.Bencode.decode(file)
    mi = MetaInfo.new(m)

    last_piece_length = MetaInfo.last_piece_length(mi)

    assert MetaInfo.last_piece?(mi, 29)

    assert MetaInfo.blocks_for_piece(mi, 29, 2 ** 14) ==
             [{0, 16384}, {16384, last_piece_length - 16384}]
  end
end
