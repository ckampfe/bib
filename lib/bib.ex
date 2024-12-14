defmodule Bib do
  # big stuff to do:
  # - [ ] seeding
  # - [ ] actual peer choke/unchoke/upload algorithm
  # - [ ] tracking of upload/download stats per peer
  # - [ ] configurability (connection limits, etc.)

  alias Bib.{Bencode, MetaInfo}

  @moduledoc """
  Documentation for `Bib`.
  """

  def start_torrent(torrent_file, download_location) do
    with {:ok, metainfo_binary} <- File.read(torrent_file),
         {:ok, decoded, <<>>} <- Bencode.decode(metainfo_binary),
         info_hash = MetaInfo.new(decoded),
         {:ok, _pid} <-
           Bib.TorrentsSupervisor.start_child(%{
             info_hash: info_hash,
             torrent_file: torrent_file,
             download_location: download_location
           }) do
      {:ok, info_hash}
    end
  end

  def stop_torrent(info_hash) do
    Bib.TorrentsSupervisor.stop_child(info_hash)
  end

  def s() do
    start_torrent("/Users/clark/code/bib/a8dmfmt66t211.png.torrent", "/Users/clark/code/bib")
  end
end
