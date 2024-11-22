defmodule Bib.MetaInfo do
  alias Bib.Bencode
  defstruct [:inner]

  def new(m) when is_map(m) do
    %__MODULE__{inner: m}
  end

  def announce(%__MODULE__{} = self) do
    %{"announce" => announce} = self.inner
    announce
  end

  def length(%__MODULE__{} = self) do
    %{"info" => %{"length" => length}} = self.inner
    length
  end

  def name(%__MODULE__{} = self) do
    %{"info" => %{"name" => name}} = self.inner
    name
  end

  @doc """
  The nominal piece length.
  Does not take into account a truncated final piece.
  """
  def piece_length(%__MODULE__{} = self) do
    %{"info" => %{"piece length" => piece_length}} = self.inner
    piece_length
  end

  @doc """
  The actual length of a given piece.
  If piece is the last piece, computes its actual length,
  otherewise returns `piece_length/1`
  """
  def actual_piece_length(%__MODULE__{} = self, index) do
    if last_piece?(self, index) do
      last_piece_length(self)
    else
      piece_length(self)
    end
  end

  @doc """
  A list of the 20-byte SHA-1 hashes of the pieces, in order.
  """
  def pieces(%__MODULE__{} = self) do
    for <<piece::binary-size(20) <- pieces_raw(self)>> do
      piece
    end
  end

  @doc """
  The total number of pieces in the torrent.
  """
  def number_of_pieces(%__MODULE__{} = self) do
    round(__MODULE__.length(self) / piece_length(self))
  end

  @doc """
  The raw `pieces` string from the MetaInfo.
  Has length `20 * number_of_pieces`
  """
  def pieces_raw(%__MODULE__{} = self) do
    %{"info" => %{"pieces" => pieces}} = self.inner
    pieces
  end

  @doc """
  The info hash identifying the torrent.
  """
  def info_hash(%__MODULE__{} = self) do
    %{"info" => info} = self.inner
    encoded_info = Bencode.encode(info)
    :crypto.hash(:sha, encoded_info)
  end

  @doc """
  The computed length of the last piece.
  """
  def last_piece_length(%__MODULE__{} = self) do
    actual_length = __MODULE__.length(self)

    if rem(actual_length, piece_length(self)) == 0 do
      piece_length(self)
    else
      length_as_if_exact_multiple_of_piece_length = number_of_pieces(self) * piece_length(self)
      actual_length - (length_as_if_exact_multiple_of_piece_length - piece_length(self))
    end
  end

  def last_piece?(%__MODULE__{} = self, index) when is_integer(index) do
    index == number_of_pieces(self) - 1
  end

  def piece_offset(%__MODULE__{} = self, index) when is_integer(index) do
    index * piece_length(self)
  end
end
