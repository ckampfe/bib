defmodule Bib.FileOps do
  @moduledoc """
  Functions to deal with reading and writing the data files that each
  torrent downloads and uploads.

  This module does not deal with .torrent metainfo.
  See the `MetaInfo` and `Bencode` modules for that.
  """

  alias Bib.{MetaInfo, Bitfield}
  import Bib.Macros

  def verify_local_data(info_hash, path) when is_info_hash(info_hash) and is_binary(path) do
    number_of_pieces = MetaInfo.number_of_pieces(info_hash)

    0..(number_of_pieces - 1)
    |> Task.async_stream(fn index ->
      {:ok, fd} = :file.open(path, [:read, :raw])

      try do
        {piece_matches_expected_hash?(info_hash, fd, index), index}
      after
        :file.close(fd)
      end
    end)
    |> Enum.reduce(
      <<0::size(number_of_pieces)>>,
      fn
        {:ok, {{:ok, true}, index}}, pieces ->
          Bitfield.set_bit(pieces, index)

        _, pieces ->
          pieces
      end
    )
  end

  def read_block(info_hash, path, index, begin, length) when is_info_hash(info_hash) do
    {:ok, fd} = :file.open(path, [:read, :raw])

    try do
      piece_offset = MetaInfo.piece_offset(info_hash, index)
      :file.pread(fd, piece_offset + begin, length)
    after
      :file.close(fd)
    end
  end

  def write_block_and_verify_piece(info_hash, path, index, begin, block)
      when is_info_hash(info_hash) do
    {:ok, fd} = :file.open(path, [:write, :read, :raw, :binary])

    try do
      with :ok <- write_block(fd, info_hash, index, begin, block),
           {:ok, matches?} <- piece_matches_expected_hash?(info_hash, fd, index) do
        {:ok, matches?}
      end
    after
      :file.close(fd)
    end
  end

  def write_block(fd, info_hash, index, begin, block) when is_info_hash(info_hash) do
    piece_offset = MetaInfo.piece_offset(info_hash, index)

    with :ok <- :file.pwrite(fd, piece_offset + begin, block),
         :ok <- :file.sync(fd) do
      :ok
    end
  end

  def piece_matches_expected_hash?(info_hash, fd, index) when is_info_hash(info_hash) do
    piece_offset = index * MetaInfo.piece_length(info_hash)

    actual_piece_length = MetaInfo.actual_piece_length(info_hash, index)

    with {:ok, piece} <- :file.pread(fd, piece_offset, actual_piece_length),
         piece_hash = Enum.at(MetaInfo.pieces(info_hash), index) do
      {:ok, hash_piece(piece) == piece_hash}
    end
  end

  def create_blank_file(path, length) when is_binary(path) and is_integer(length) do
    {:ok, fd} = :file.open(path, [:exclusive, :raw])

    try do
      with {:ok, _} <- :file.position(fd, length),
           :ok <- :file.truncate(fd) do
        :ok
      end
    after
      :file.close(fd)
    end
  end

  def hash_piece(piece) do
    :crypto.hash(:sha, piece)
  end
end
