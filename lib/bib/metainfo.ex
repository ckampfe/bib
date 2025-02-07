defmodule Bib.MetaInfo do
  @moduledoc """
  Access functions for the .torrent metainfo data
  that each torrent uses.

  This data is immutable.
  It is stored one time in `:persistent_term` on creation and then
  never touched again until deletion.
  """

  alias Bib.{Bencode, Bitfield}
  import Bib.Macros

  defstruct [:inner]

  @doc """
  create a new metainfo and store it in `:persistent_term` storage
  under the key `{Bib.MetInfo, torrent_file}`.

  The metainfo is immutable so we can store this for the entire life of the torrent,
  until the user intentionally removes it.
  """
  def new(m) when is_map(m) do
    metainfo = %__MODULE__{inner: m}
    %{"info" => info} = metainfo.inner
    encoded_info = Bencode.encode(info)
    info_hash = :crypto.hash(:sha, encoded_info)
    :ok = :persistent_term.put(key(info_hash), metainfo)
    info_hash
  end

  @doc """
  the tracker announce url
  """
  def announce(info_hash) when is_info_hash(info_hash) do
    self = :persistent_term.get(key(info_hash))
    %{"announce" => announce} = self.inner
    announce
  end

  @doc """
  the length of the torrent, in bytes
  """
  def length(info_hash) when is_info_hash(info_hash) do
    self = :persistent_term.get(key(info_hash))
    %{"info" => %{"length" => length}} = self.inner
    length
  end

  @doc """
  the filename
  """
  def name(info_hash) when is_info_hash(info_hash) do
    self = :persistent_term.get(key(info_hash))
    %{"info" => %{"name" => name}} = self.inner
    name
  end

  # # TODO
  # # multiple files
  # # have schema:
  # # %{length: integer, path: [string]}
  # def files(info_hash) when is_info_hash(info_hash) do
  #   self = :persistent_term.get({__MODULE__, info_hash})
  #   %{"info" => %{"files" => files}} = self.inner
  #   files
  # end

  @doc """
  The nominal piece length.
  Does not take into account a truncated final piece.
  """
  def piece_length(info_hash) when is_info_hash(info_hash) do
    self = :persistent_term.get(key(info_hash))
    %{"info" => %{"piece length" => piece_length}} = self.inner
    piece_length
  end

  @doc """
  The actual length of a given piece.
  If piece is the last piece, computes its actual length,
  otherewise returns `piece_length/1`
  """
  def actual_piece_length(info_hash, index)
      when is_info_hash(info_hash) and is_integer(index) do
    if last_piece?(info_hash, index) do
      last_piece_length(info_hash)
    else
      piece_length(info_hash)
    end
  end

  @doc """
  A list of the 20-byte SHA-1 hashes of the pieces, in order.
  """
  def pieces(info_hash) when is_info_hash(info_hash) do
    for <<piece::binary-size(20) <- pieces_raw(info_hash)>> do
      piece
    end
  end

  @doc """
  The total number of pieces in the torrent.
  """
  def number_of_pieces(info_hash) when is_info_hash(info_hash) do
    Kernel.ceil(__MODULE__.length(info_hash) / piece_length(info_hash))
  end

  @doc """
  return the number of bytes remaining to finish the download
  """
  def left(info_hash, pieces) when is_info_hash(info_hash) do
    unset_indexes = Bitfield.unset_indexes(pieces)

    for index <- unset_indexes, reduce: 0 do
      acc ->
        if last_piece?(info_hash, index) do
          acc + last_piece_length(info_hash)
        else
          acc + piece_length(info_hash)
        end
    end
  end

  @doc """
  The raw `pieces` string from the MetaInfo.
  Has length `20 * number_of_pieces`
  """
  def pieces_raw(info_hash) when is_info_hash(info_hash) do
    self = :persistent_term.get(key(info_hash))
    %{"info" => %{"pieces" => pieces}} = self.inner
    pieces
  end

  @doc """
  The computed length of the last piece.
  """
  def last_piece_length(info_hash) when is_info_hash(info_hash) do
    actual_length = __MODULE__.length(info_hash)

    if rem(actual_length, piece_length(info_hash)) == 0 do
      piece_length(info_hash)
    else
      length_as_if_exact_multiple_of_piece_length =
        number_of_pieces(info_hash) * piece_length(info_hash)

      actual_length - (length_as_if_exact_multiple_of_piece_length - piece_length(info_hash))
    end
  end

  def last_piece?(info_hash, index) when is_info_hash(info_hash) and is_integer(index) do
    index == number_of_pieces(info_hash) - 1
  end

  def piece_offset(info_hash, index)
      when is_info_hash(info_hash) and is_integer(index) do
    index * piece_length(info_hash)
  end

  def blocks_for_piece(info_hash, index, block_length)
      when is_info_hash(info_hash) and
             is_integer(index) and
             is_integer(block_length) do
    actual_piece_length = actual_piece_length(info_hash, index)

    number_of_full_blocks =
      Kernel.floor(actual_piece_length / block_length)

    nominal_piece_length = piece_length(info_hash)

    blocks =
      for block_number <- 0..(number_of_full_blocks - 1) do
        {block_number * block_length, block_length}
      end

    if actual_piece_length < nominal_piece_length do
      {s_to_last_offset, s_to_last_length} = :lists.last(blocks)
      last_block_length = actual_piece_length - (s_to_last_offset + s_to_last_length)

      blocks ++ [{s_to_last_offset + s_to_last_length, last_block_length}]
    else
      blocks
    end
  end

  @doc """
  The key used to look up metainfo in the :persistent_term database
  """
  def key(info_hash) when is_info_hash(info_hash) do
    {__MODULE__, info_hash}
  end
end
