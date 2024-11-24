defmodule Bib.FileOps do
  alias Bib.{MetaInfo, Bitfield}

  def verify_local_data(torrent_file, path) when is_binary(path) do
    {:ok, fd} = :file.open(path, [:read, :raw])

    number_of_pieces = MetaInfo.number_of_pieces(torrent_file)

    0..(number_of_pieces - 1)
    |> Enum.reduce(<<0::size(number_of_pieces)>>, fn index, pieces ->
      case piece_matches_expected_hash?(torrent_file, fd, index) do
        {:ok, true} ->
          Bitfield.set_bit(pieces, index)

        {:ok, false} ->
          pieces
      end
    end)
  end

  def write_block_and_verify_piece(torrent_file, path, index, begin, block) do
    with {:ok, fd} = :file.open(path, [:write, :read, :raw, :binary]),
         :ok <- write_block(fd, torrent_file, index, begin, block),
         {:ok, matches?} <- piece_matches_expected_hash?(torrent_file, fd, index) do
      {:ok, matches?}
    end
  end

  def write_block(fd, torrent_file, index, begin, block) do
    piece_offset = MetaInfo.piece_offset(torrent_file, index)

    with :ok <- :file.pwrite(fd, piece_offset + begin, block),
         :ok <- :file.sync(fd) do
      :ok
    end
  end

  def piece_matches_expected_hash?(torrent_file, fd, index) do
    piece_offset = index * MetaInfo.piece_length(torrent_file)

    actual_piece_length = MetaInfo.actual_piece_length(torrent_file, index)

    with {:ok, piece} <- :file.pread(fd, piece_offset, actual_piece_length),
         piece_hash = Enum.at(MetaInfo.pieces(torrent_file), index) do
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
