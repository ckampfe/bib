defmodule Bib do
  import Bib.Macros
  alias Bib.Torrent

  # big stuff to do:
  # - [ ] seeding
  # - [ ] actual peer choke/unchoke/upload algorithm
  # - [ ] tracking of upload/download stats per peer
  # - [ ] configurability (connection limits, etc.)
  # - [ ] mutliple files in a single torrent
  # - [ ] force update tracker
  # - [x] verify local data
  # - [x] remove torrent
  # - [x] pause torrent
  # - [x] resume torrent

  alias Bib.{Bencode, MetaInfo}

  @moduledoc """
  Documentation for `Bib`.
  """

  def add_torrent(torrent_file, download_location) do
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

  def pause_torrent(info_hash) when is_info_hash(info_hash) do
    Torrent.pause(info_hash)
  end

  def resume_torrent(info_hash) when is_info_hash(info_hash) do
    Torrent.resume(info_hash)
  end

  def remove_torrent(info_hash) when is_info_hash(info_hash) do
    pause_torrent(info_hash)
    :persistent_term.erase(Bib.MetaInfo.key(info_hash))
    :ok
  end

  def update_tracker(info_hash) when is_info_hash(info_hash) do
    raise "todo"
  end

  def verify_local_data(info_hash) when is_info_hash(info_hash) do
    Torrent.verify_local_data(info_hash)
  end

  def s() do
    add_torrent("/Users/clark/code/bib/a8dmfmt66t211.png.torrent", "/Users/clark/code/bib")
  end
end
