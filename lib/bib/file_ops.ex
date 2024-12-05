defmodule Bib.FileOps do
  alias Bib.{MetaInfo, Bitfield}

  def verify_local_data(info_hash, path) when is_binary(path) do
    {:ok, fd} = :file.open(path, [:read, :raw])

    number_of_pieces = MetaInfo.number_of_pieces(info_hash)

    0..(number_of_pieces - 1)
    |> Enum.reduce(<<0::size(number_of_pieces)>>, fn index, pieces ->
      case piece_matches_expected_hash?(info_hash, fd, index) do
        {:ok, true} ->
          Bitfield.set_bit(pieces, index)

        {:ok, false} ->
          pieces
      end
    end)
  end

  def read_block(info_hash, path, index, begin, length) do
    {:ok, fd} = :file.open(path, [:read, :raw])
    piece_offset = MetaInfo.piece_offset(info_hash, index)
    :file.pread(fd, piece_offset + begin, length)
  end

  def write_block_and_verify_piece(info_hash, path, index, begin, block) do
    with {:ok, fd} <- :file.open(path, [:write, :read, :raw, :binary]),
         :ok <- write_block(fd, info_hash, index, begin, block),
         {:ok, matches?} <- piece_matches_expected_hash?(info_hash, fd, index) do
      {:ok, matches?}
    end
  end

  def write_block(fd, info_hash, index, begin, block) do
    piece_offset = MetaInfo.piece_offset(info_hash, index)

    with :ok <- :file.pwrite(fd, piece_offset + begin, block),
         :ok <- :file.sync(fd) do
      :ok
    end
  end

  def piece_matches_expected_hash?(info_hash, fd, index) do
    piece_offset = index * MetaInfo.piece_length(info_hash)

    actual_piece_length = MetaInfo.actual_piece_length(info_hash, index)

    with {:ok, piece} <- :file.pread(fd, piece_offset, actual_piece_length),
         piece_hash = Enum.at(MetaInfo.pieces(info_hash), index) do
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
