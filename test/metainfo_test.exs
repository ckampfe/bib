defmodule MetaInfoTest do
  use ExUnit.Case
  alias Bib.MetaInfo

  test "metainfo" do
    torrent_file = "The-Fanimatrix-(DivX-5.1-HQ).avi.torrent"
    file = File.read!(torrent_file)
    {:ok, m, _} = Bib.Bencode.decode(file)

    pieces = m |> get_in(["info", "pieces"])

    info_hash = MetaInfo.new(m)
    assert MetaInfo.announce(info_hash) == "http://kaos.gen.nz:6969/announce"
    assert MetaInfo.length(info_hash) == 135_046_574
    assert MetaInfo.name(info_hash) == "The-Fanimatrix-(DivX-5.1-HQ).avi"
    assert MetaInfo.piece_length(info_hash) == 262_144
    assert MetaInfo.pieces_raw(info_hash) == pieces

    assert Enum.all?(MetaInfo.pieces(info_hash), fn piece ->
             byte_size(piece) == 20
           end)
  end

  test "blocks_for_piece/3" do
    torrent_file = "The-Fanimatrix-(DivX-5.1-HQ).avi.torrent"
    file = File.read!(torrent_file)
    {:ok, m, _} = Bib.Bencode.decode(file)
    info_hash = MetaInfo.new(m)

    assert MetaInfo.blocks_for_piece(info_hash, 0, 2 ** 14) ==
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

    torrent_file = "a8dmfmt66t211.png.torrent"
    file = File.read!(torrent_file)
    {:ok, m, _} = Bib.Bencode.decode(file)
    info_hash = MetaInfo.new(m)

    last_piece_length = MetaInfo.last_piece_length(info_hash)

    assert MetaInfo.last_piece?(info_hash, 29)

    assert MetaInfo.blocks_for_piece(info_hash, 29, 2 ** 14) ==
             [{0, 16384}, {16384, last_piece_length - 16384}]
  end
end
