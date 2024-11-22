defmodule Bib.FileOps do
  alias Bib.{MetaInfo, Bitfield}

  def verify_local_data(path, %MetaInfo{} = metainfo) when is_binary(path) do
    {:ok, fd} = :file.open(path, [:read, :raw])

    number_of_pieces = MetaInfo.number_of_pieces(metainfo)

    0..(number_of_pieces - 1)
    |> Enum.reduce(<<0::size(number_of_pieces)>>, fn index, pieces ->
      if piece_matches_expected_hash?(fd, index, metainfo) do
        Bitfield.set_bit(pieces, index)
      else
        pieces
      end
    end)
  end

  def write_block_and_verify_piece(path, metainfo, index, begin, block) do
    with {:ok, fd} = :file.open(path, [:write, :read, :raw, :binary]),
         :ok <- write_block(fd, begin, block),
         {:ok, matches?} <- piece_matches_expected_hash?(fd, index, metainfo) do
      {:ok, matches?}
    end
  end

  def write_block(fd, begin, block) do
    with :ok <- :file.pwrite(fd, begin, block),
         :ok <- :file.sync(fd) do
      :ok
    end
  end

  def piece_matches_expected_hash?(fd, index, metainfo) do
    piece_offset = index * MetaInfo.piece_length(metainfo)

    actual_piece_length = MetaInfo.actual_piece_length(metainfo, index)

    with {:ok, piece} <- :file.pread(fd, piece_offset, actual_piece_length),
         piece_hash = Enum.at(MetaInfo.pieces(metainfo), index) do
      {:ok, hash_piece(piece) == piece_hash}
    end
  end

  def create_blank_file(path, length) when is_binary(path) and is_integer(length) do
    with {:ok, fd} <-
           :file.open(path, [
             :exclusive,
             :raw
           ]),
         {:ok, _} <- :file.position(fd, length),
         :ok <- :file.truncate(fd) do
      :ok
    end
  end

  def hash_piece(piece) do
    :crypto.hash(:sha, piece)
  end
end
