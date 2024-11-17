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

  def piece_length(%__MODULE__{} = self) do
    %{"info" => %{"piece length" => piece_length}} = self.inner
    piece_length
  end

  def pieces(%__MODULE__{} = self) do
    for <<piece::binary-size(20) <- pieces_raw(self)>> do
      piece
    end
  end

  def pieces_raw(%__MODULE__{} = self) do
    %{"info" => %{"pieces" => pieces}} = self.inner
    pieces
  end

  def info_hash(%__MODULE__{} = self) do
    %{"info" => info} = self.inner
    encoded_info = Bencode.encode(info)
    :crypto.hash(:sha, encoded_info)
  end
end
