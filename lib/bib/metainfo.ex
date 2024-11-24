defmodule Bib.MetaInfo do
  alias Bib.Bencode
  defstruct [:inner]

  @doc """
  create a new metainfo and store it in `:persistent_term` storage
  under the key `{Bib.MetInfo, torrent_file}`.

  The metainfo is immutable so we can store this for the entire life of the torrent,
  until the user intentionally removes it.
  """
  def new(torrent_file, m) when is_binary(torrent_file) and is_map(m) do
    metainfo = %__MODULE__{inner: m}
    :persistent_term.put({__MODULE__, torrent_file}, metainfo)
  end

  def announce(torrent_file) when is_binary(torrent_file) do
    self = :persistent_term.get({__MODULE__, torrent_file})
    %{"announce" => announce} = self.inner
    announce
  end

  def length(torrent_file) when is_binary(torrent_file) do
    self = :persistent_term.get({__MODULE__, torrent_file})
    %{"info" => %{"length" => length}} = self.inner
    length
  end

  def name(torrent_file) when is_binary(torrent_file) do
    self = :persistent_term.get({__MODULE__, torrent_file})
    %{"info" => %{"name" => name}} = self.inner
    name
  end

  @doc """
  The nominal piece length.
  Does not take into account a truncated final piece.
  """
  def piece_length(torrent_file) when is_binary(torrent_file) do
    self = :persistent_term.get({__MODULE__, torrent_file})
    %{"info" => %{"piece length" => piece_length}} = self.inner
    piece_length
  end

  @doc """
  The actual length of a given piece.
  If piece is the last piece, computes its actual length,
  otherewise returns `piece_length/1`
  """
  def actual_piece_length(torrent_file, index)
      when is_binary(torrent_file) and is_integer(index) do
    if last_piece?(torrent_file, index) do
      last_piece_length(torrent_file)
    else
      piece_length(torrent_file)
    end
  end

  @doc """
  A list of the 20-byte SHA-1 hashes of the pieces, in order.
  """
  def pieces(torrent_file) when is_binary(torrent_file) do
    for <<piece::binary-size(20) <- pieces_raw(torrent_file)>> do
      piece
    end
  end

  @doc """
  The total number of pieces in the torrent.
  """
  def number_of_pieces(torrent_file) when is_binary(torrent_file) do
    round(__MODULE__.length(torrent_file) / piece_length(torrent_file))
  end

  @doc """
  The raw `pieces` string from the MetaInfo.
  Has length `20 * number_of_pieces`
  """
  def pieces_raw(torrent_file) when is_binary(torrent_file) do
    self = :persistent_term.get({__MODULE__, torrent_file})
    %{"info" => %{"pieces" => pieces}} = self.inner
    pieces
  end

  @doc """
  The info hash identifying the torrent.
  """
  def info_hash(torrent_file) when is_binary(torrent_file) do
    self = :persistent_term.get({__MODULE__, torrent_file})
    %{"info" => info} = self.inner
    encoded_info = Bencode.encode(info)
    :crypto.hash(:sha, encoded_info)
  end

  @doc """
  The computed length of the last piece.
  """
  def last_piece_length(torrent_file) do
    actual_length = __MODULE__.length(torrent_file)

    if rem(actual_length, piece_length(torrent_file)) == 0 do
      piece_length(torrent_file)
    else
      length_as_if_exact_multiple_of_piece_length =
        number_of_pieces(torrent_file) * piece_length(torrent_file)

      actual_length - (length_as_if_exact_multiple_of_piece_length - piece_length(torrent_file))
    end
  end

  def last_piece?(torrent_file, index) when is_binary(torrent_file) and is_integer(index) do
    index == number_of_pieces(torrent_file) - 1
  end

  def piece_offset(torrent_file, index)
      when is_binary(torrent_file) and is_integer(index) do
    index * piece_length(torrent_file)
  end

  def blocks_for_piece(torrent_file, index, block_length)
      when is_binary(torrent_file) and
             is_integer(index) and
             is_integer(block_length) do
    actual_piece_length = actual_piece_length(torrent_file, index)

    number_of_full_blocks =
      Kernel.floor(actual_piece_length / block_length)

    nominal_piece_length = piece_length(torrent_file)

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
end
